"""
Bot-facing API endpoints. Authenticated via X-Bot-Key header rather than
session cookies so the Discord bot can call them without a browser session.
"""
from pathlib import Path
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, Header
from fastapi.responses import FileResponse
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func
from sqlalchemy.orm.attributes import flag_modified
from ..database import get_db
from ..models import Campaign, CampaignMember, SessionNote, User, FuzionSessionLog
from ..config import settings
# FuzionCharacter / _display_image are imported lazily inside the one
# Fuzion-specific endpoint below — a build without the Fuzion module (the
# public open-core edition) still needs the rest of this router.

router = APIRouter(prefix="/bot", tags=["bot"])


def require_bot(x_bot_key: str = Header(default="")):
    if not settings.bot_api_key or x_bot_key != settings.bot_api_key:
        raise HTTPException(status_code=401, detail="Invalid bot API key")


# ── Schemas ───────────────────────────────────────────────────────────────────

class SessionStart(BaseModel):
    guild_id: str
    campaign_name: str
    session_number: Optional[int] = None  # auto-increment if omitted


class SessionEnd(BaseModel):
    session_id: str
    summary: Optional[str] = None


class NoteCreate(BaseModel):
    session_id: str
    content: str
    is_gm_only: bool = False


class RollChannelSet(BaseModel):
    guild_id: str
    campaign_name: Optional[str] = None
    channel_id: str


# ── Endpoints ─────────────────────────────────────────────────────────────────

@router.get("/campaigns", dependencies=[Depends(require_bot)])
async def find_campaign(
    guild_id: str,
    name: str,
    db: AsyncSession = Depends(get_db),
):
    """Look up an active campaign by guild and name (case-insensitive)."""
    result = await db.execute(
        select(Campaign).where(
            Campaign.status == "active" if hasattr(Campaign, "status") else True,
        )
    )
    # Filter in Python for case-insensitive match across all campaigns in guild
    # (guild_id is stored on sessions, not campaigns — use members as proxy)
    campaigns = result.scalars().all()
    match = next((c for c in campaigns if c.name.lower() == name.lower()), None)
    if not match:
        raise HTTPException(404, f"No active campaign named '{name}'")
    return {
        "id": match.id,
        "name": match.name,
        "description": match.description,
        "game_system_id": match.game_system_id,
    }


@router.post("/sessions/start", dependencies=[Depends(require_bot)])
async def start_session(body: SessionStart, db: AsyncSession = Depends(get_db)):
    """Create a session-start note for a campaign."""
    # Find campaign by name
    result = await db.execute(
        select(Campaign).where(
            func.lower(Campaign.name) == body.campaign_name.lower()
        )
    )
    campaign = result.scalar_one_or_none()
    if not campaign:
        raise HTTPException(404, f"No campaign named '{body.campaign_name}'")

    # Determine next session number
    if body.session_number:
        session_num = body.session_number
    else:
        count_result = await db.execute(
            select(func.max(SessionNote.session_number)).where(
                SessionNote.campaign_id == campaign.id
            )
        )
        max_num = count_result.scalar_one_or_none() or 0
        session_num = max_num + 1

    note = SessionNote(
        campaign_id=campaign.id,
        author_id=None,
        session_number=session_num,
        title=f"Session {session_num}",
        content="",
        is_gm_only=False,
    )
    db.add(note)
    await db.commit()
    await db.refresh(note)

    return {
        "session_id": note.id,
        "campaign_id": campaign.id,
        "campaign_name": campaign.name,
        "session_number": session_num,
    }


@router.patch("/sessions/{session_id}/end", dependencies=[Depends(require_bot)])
async def end_session(
    session_id: str,
    body: SessionEnd,
    db: AsyncSession = Depends(get_db),
):
    """Finalise a session note with an optional summary."""
    note = await db.get(SessionNote, session_id)
    if not note:
        raise HTTPException(404, "Session not found")

    if body.summary:
        note.content = body.summary

    await db.commit()
    return {"ok": True, "session_number": note.session_number}


@router.post("/sessions/{session_id}/notes", dependencies=[Depends(require_bot)])
async def add_note(
    session_id: str,
    body: NoteCreate,
    db: AsyncSession = Depends(get_db),
):
    """Append a mid-session text note."""
    parent = await db.get(SessionNote, session_id)
    if not parent:
        raise HTTPException(404, "Session not found")

    # Append to the parent session note's content
    separator = "\n\n---\n\n" if parent.content else ""
    parent.content = parent.content + separator + body.content
    await db.commit()
    return {"ok": True}


# ── Roll channel relay ───────────────────────────────────────────────────────
#
# Dice rolls made in the Sanctum web app land in fuzion_session_logs with
# kind="roll". A designated Discord channel gets those relayed to it so the
# table can see results without anyone tabbing back to the browser. The
# guild/channel pair lives in campaign.settings (same JSON blob the app's own
# GM settings use) rather than a new column — set via /set_roll_channel.

@router.post("/campaigns/roll-channel", dependencies=[Depends(require_bot)])
async def set_roll_channel(body: RollChannelSet, db: AsyncSession = Depends(get_db)):
    """Point a campaign's Discord roll relay at a guild + channel.

    campaign_name is optional — most setups only ever have one campaign, so
    if it's omitted and there's exactly one in Sanctum, that's the one. Only
    matters once a second campaign exists.
    """
    if body.campaign_name:
        result = await db.execute(
            select(Campaign).where(func.lower(Campaign.name) == body.campaign_name.lower())
        )
        campaign = result.scalar_one_or_none()
        if not campaign:
            raise HTTPException(404, f"No campaign named '{body.campaign_name}'")
    else:
        result = await db.execute(select(Campaign))
        campaigns = result.scalars().all()
        if not campaigns:
            raise HTTPException(404, "No campaigns exist in Sanctum yet")
        if len(campaigns) > 1:
            names = ", ".join(c.name for c in campaigns)
            raise HTTPException(409, f"Multiple campaigns exist ({names}) — specify one with the game option")
        campaign = campaigns[0]

    s = dict(campaign.settings or {})
    s["discord_guild_id"] = body.guild_id
    s["roll_channel_id"] = body.channel_id
    campaign.settings = s
    flag_modified(campaign, "settings")
    await db.commit()
    return {"ok": True, "campaign_id": campaign.id, "campaign_name": campaign.name}


@router.get("/roll-channels", dependencies=[Depends(require_bot)])
async def list_roll_channels(db: AsyncSession = Depends(get_db)):
    """Every campaign with a roll relay configured, for the bot's poll loop."""
    result = await db.execute(select(Campaign))
    out = []
    for c in result.scalars().all():
        s = c.settings or {}
        guild_id = s.get("discord_guild_id")
        channel_id = s.get("roll_channel_id")
        if guild_id and channel_id:
            out.append({
                "campaign_id": c.id, "campaign_name": c.name,
                "guild_id": guild_id, "channel_id": channel_id,
            })
    return out


@router.get("/characters/{char_id}/portrait", dependencies=[Depends(require_bot)])
async def get_character_portrait(char_id: str, db: AsyncSession = Depends(get_db)):
    """Primary album image for a character — used as the Discord roll-relay
    thumbnail. Bot-key auth only; the bot re-serves the bytes to Discord as an
    attachment so nothing here is publicly reachable."""
    try:
        from ..models_fuzion import FuzionCharacter
        from .fuzion import _display_image
    except ImportError:
        raise HTTPException(404, "Fuzion not available in this build")
    char = await db.get(FuzionCharacter, char_id)
    if not char:
        raise HTTPException(404, "No such character")
    img = _display_image(char.data or {})
    if not img:
        raise HTTPException(404, "No portrait")
    path = Path(settings.campaign_files_path) / img["path"]
    if not path.exists():
        raise HTTPException(404, "Portrait missing on disk")
    return FileResponse(path, media_type=img.get("mime") or "image/jpeg")


@router.get("/campaigns/{campaign_id}/rolls", dependencies=[Depends(require_bot)])
async def get_recent_rolls(
    campaign_id: str,
    since_id: Optional[str] = None,
    db: AsyncSession = Depends(get_db),
):
    """Roll log entries newer than since_id (exclusive), oldest first.

    since_id omitted or not found in the returned window just means "nothing
    new yet" to the caller — it doesn't error, since a restarted bot or a
    freshly-set roll channel has no prior checkpoint to compare against.
    """
    stmt = (
        select(FuzionSessionLog)
        .where(FuzionSessionLog.campaign_id == campaign_id, FuzionSessionLog.kind == "roll")
        .order_by(FuzionSessionLog.created_at.desc())
        .limit(50)
    )
    rows = (await db.execute(stmt)).scalars().all()
    rows.reverse()
    if since_id:
        idx = next((i for i, r in enumerate(rows) if r.id == since_id), None)
        if idx is not None:
            rows = rows[idx + 1:]
    return [{
        "id": r.id, "author_name": r.author_name, "source": r.source,
        "payload": r.payload, "created_at": r.created_at.isoformat() if r.created_at else None,
    } for r in rows]
