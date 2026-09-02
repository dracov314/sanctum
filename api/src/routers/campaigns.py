import os
import re
import json
import uuid
import secrets
import mimetypes
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, UploadFile, File
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func
from sqlalchemy.orm.attributes import flag_modified
from ..database import get_db
from ..models import (
    Campaign, CampaignMember, CampaignCategory, CampaignFile, CampaignInvite,
    SessionNote, GMSessionNote, PlayerSessionNote, SessionPoll, SessionPollResponse,
    WikiPage, WikiTemplate, CampaignResource, User, FuzionSessionLog, GameSystem,
)
from ..auth import get_current_user
from ..config import settings

router = APIRouter(prefix="/campaigns", tags=["campaigns"])


# ── Schemas ───────────────────────────────────────────────────────────────────

class CampaignCreate(BaseModel):
    name: str
    description: Optional[str] = None
    game_system_id: Optional[str] = None
    is_private: bool = True


class CampaignUpdate(BaseModel):
    name: Optional[str] = None
    description: Optional[str] = None
    game_system_id: Optional[str] = None
    is_private: Optional[bool] = None


class NoteCreate(BaseModel):
    session_number: int
    title: str
    content: str = ""
    is_gm_only: bool = False


class NoteUpdate(BaseModel):
    title: Optional[str] = None
    content: Optional[str] = None
    is_gm_only: Optional[bool] = None
    xp_awarded: Optional[int] = None


class EndSession(BaseModel):
    xp_awarded: int = 0


class GMNotesUpdate(BaseModel):
    private_notes: Optional[str] = None


class PlayerNotesUpdate(BaseModel):
    content: str


class WikiPageCreate(BaseModel):
    title: str
    content: str = ""
    is_gm_only: bool = False
    parent_id: Optional[str] = None
    sort_order: int = 0


class WikiPageUpdate(BaseModel):
    title: Optional[str] = None
    content: Optional[str] = None
    is_gm_only: Optional[bool] = None
    parent_id: Optional[str] = None
    sort_order: Optional[int] = None


class WikiTemplateCreate(BaseModel):
    name: str
    content: str = ""


class WikiPageImport(BaseModel):
    title: str
    content: str = ""
    is_gm_only: bool = False
    parent_id: Optional[str] = None
    sort_order: int = 0
    id: Optional[str] = None  # the exported page's own id, used only for parent remapping


class ResourceCreate(BaseModel):
    name: str
    resource_type: str  # "link" | "book"
    url: Optional[str] = None
    book_id: Optional[str] = None
    category_id: Optional[str] = None
    sort_order: int = 0


class CategoryCreate(BaseModel):
    name: str
    icon: Optional[str] = None
    sort_order: int = 0


class CharacterUpdate(BaseModel):
    character_name: Optional[str] = None
    character_art_path: Optional[str] = None
    character_sheet_url: Optional[str] = None


class MemberAdd(BaseModel):
    username: str
    role: str = "player"


class InviteCreate(BaseModel):
    role: str = "player"                       # "player" | "gm"
    max_uses: Optional[int] = None             # None = unlimited
    expires_in_days: Optional[int] = None      # None = never


# ── Helpers ───────────────────────────────────────────────────────────────────

def _slugify(title: str) -> str:
    slug = title.lower().strip()
    slug = re.sub(r"[^\w\s-]", "", slug)
    slug = re.sub(r"[\s_-]+", "-", slug)
    return slug.strip("-")


_DEFAULT_CAMPAIGN_SETTINGS = {
    "starting_cp": 40,
    "starting_op": 10,
}


def _campaign_out(c: Campaign, role: str, *, system_slug: Optional[str] = None) -> dict:
    raw = c.settings or {}
    s = {**_DEFAULT_CAMPAIGN_SETTINGS, **raw}
    return {
        "id": c.id,
        "name": c.name,
        "description": c.description,
        "game_system_id": c.game_system_id,
        # Stable slug for the game system (e.g. "fuzion"). game_system_id is a
        # per-install UUID, so the frontend's session-room dispatch keys on this.
        "system_slug": system_slug,
        "owner_id": c.owner_id,
        "is_private": c.is_private,
        "banner_url": c.banner_url,
        "created_at": c.created_at.isoformat() if c.created_at else None,
        "role": role,
        "settings": s,
    }


async def _system_slug(db: AsyncSession, game_system_id: Optional[str]) -> Optional[str]:
    if not game_system_id:
        return None
    gs = await db.get(GameSystem, game_system_id)
    # A hand-made campaign may already carry a slug rather than a real FK.
    return (gs.slug or gs.id) if gs else game_system_id


async def _get_campaign_as_member(
    campaign_id: str, user: User, db: AsyncSession, require_gm: bool = False
) -> tuple[Campaign, Optional[CampaignMember]]:
    campaign = await db.get(Campaign, campaign_id)
    if not campaign:
        raise HTTPException(404, "Campaign not found")

    if campaign.owner_id == user.id:
        return campaign, None

    member = (await db.execute(
        select(CampaignMember).where(
            CampaignMember.campaign_id == campaign_id,
            CampaignMember.user_id == user.id,
        )
    )).scalar_one_or_none()

    if not member and not user.is_admin:
        raise HTTPException(403, "Not a member of this campaign")
    if require_gm and campaign.owner_id != user.id and (not member or member.role != "gm"):
        raise HTTPException(403, "GM only")

    return campaign, member


def _is_gm(campaign: Campaign, member: Optional[CampaignMember], user: User) -> bool:
    return campaign.owner_id == user.id or (member is not None and member.role == "gm")


async def _my_member_row(campaign_id: str, user: User, db: AsyncSession) -> Optional[CampaignMember]:
    """The caller's own CampaignMember row, looked up directly by user_id.

    Unlike _get_campaign_as_member, this doesn't short-circuit to None for the
    campaign owner — an owner can also hold their own player-role member row
    (e.g. dracov in the One Piece campaign, who owns it but plays Luna), and
    self-service /members/me endpoints need that specific row, not just
    permission-to-act on the campaign in general.
    """
    return (await db.execute(
        select(CampaignMember).where(
            CampaignMember.campaign_id == campaign_id, CampaignMember.user_id == user.id
        )
    )).scalar_one_or_none()


def _member_role(campaign: Campaign, member: Optional[CampaignMember], user: User) -> str:
    if campaign.owner_id == user.id:
        return "owner"
    return member.role if member else "player"


# ── Campaign CRUD ─────────────────────────────────────────────────────────────

@router.get("")
async def list_campaigns(db: AsyncSession = Depends(get_db), user: User = Depends(get_current_user)):
    from ..models import SessionNote

    owned = (await db.execute(select(Campaign).where(Campaign.owner_id == user.id))).scalars().all()
    member_of = (await db.execute(
        select(Campaign, CampaignMember)
        .join(CampaignMember, CampaignMember.campaign_id == Campaign.id)
        .where(CampaignMember.user_id == user.id)
    )).all()

    all_campaigns: list[tuple[Campaign, str]] = [(c, "owner") for c in owned]
    owned_ids = {o.id for o in owned}
    for c, m in member_of:
        if c.id not in owned_ids:
            all_campaigns.append((c, m.role))

    # Batch-fetch the latest session note for each campaign
    campaign_ids = [c.id for c, _ in all_campaigns]
    latest_sessions: dict[str, dict] = {}
    if campaign_ids:
        max_sq = (
            select(
                SessionNote.campaign_id,
                func.max(SessionNote.session_number).label("max_num"),
            )
            .where(SessionNote.campaign_id.in_(campaign_ids))
            .group_by(SessionNote.campaign_id)
        ).subquery()
        rows = (await db.execute(
            select(SessionNote).join(
                max_sq,
                (SessionNote.campaign_id == max_sq.c.campaign_id) &
                (SessionNote.session_number == max_sq.c.max_num),
            )
        )).scalars().all()
        for sn in rows:
            latest_sessions[sn.campaign_id] = {
                "session_number": sn.session_number,
                "title": sn.title,
                "updated_at": sn.updated_at.isoformat() if sn.updated_at else None,
            }

    sys_ids = {c.game_system_id for c, _ in all_campaigns if c.game_system_id}
    slug_by_id: dict[str, str] = {}
    if sys_ids:
        for gs in (await db.execute(
            select(GameSystem).where(GameSystem.id.in_(sys_ids))
        )).scalars().all():
            slug_by_id[gs.id] = gs.slug or gs.id

    return [
        {
            **_campaign_out(c, role, system_slug=slug_by_id.get(c.game_system_id) or c.game_system_id),
            "latest_session": latest_sessions.get(c.id),
        }
        for c, role in all_campaigns
    ]


@router.post("", status_code=201)
async def create_campaign(
    body: CampaignCreate,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    campaign = Campaign(
        name=body.name,
        description=body.description,
        game_system_id=body.game_system_id,
        is_private=body.is_private,
        owner_id=user.id,
    )
    db.add(campaign)
    await db.commit()
    await db.refresh(campaign)
    return _campaign_out(campaign, "owner",
                         system_slug=await _system_slug(db, campaign.game_system_id))


@router.get("/{campaign_id}")
async def get_campaign(
    campaign_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    campaign, member = await _get_campaign_as_member(campaign_id, user, db)
    return _campaign_out(
        campaign, _member_role(campaign, member, user),
        system_slug=await _system_slug(db, campaign.game_system_id),
    )


class CampaignSettingsUpdate(BaseModel):
    starting_cp: Optional[int] = None
    starting_op: Optional[int] = None
    # Game budget & session fields (campaign redesign)
    power_level: Optional[str] = None        # everyday|competent|heroic|incredible|legendary|custom
    cp: Optional[int] = None
    op: Optional[int] = None
    op_granted: Optional[int] = None
    custom_rules: Optional[str] = None


@router.patch("/{campaign_id}/settings")
async def update_campaign_settings(
    campaign_id: str,
    body: CampaignSettingsUpdate,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    campaign, _ = await _get_campaign_as_member(campaign_id, user, db, require_gm=True)
    current = dict(campaign.settings or {})
    for k, v in body.model_dump(exclude_none=True).items():
        current[k] = v
    campaign.settings = current
    flag_modified(campaign, "settings")
    await db.commit()
    await db.refresh(campaign)
    return _campaign_out(campaign, "owner",
                         system_slug=await _system_slug(db, campaign.game_system_id))



@router.patch("/{campaign_id}")
async def update_campaign(
    campaign_id: str,
    body: CampaignUpdate,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    campaign, _ = await _get_campaign_as_member(campaign_id, user, db, require_gm=True)
    for field, value in body.model_dump(exclude_none=True).items():
        setattr(campaign, field, value)
    await db.commit()
    await db.refresh(campaign)
    return _campaign_out(campaign, "owner",
                         system_slug=await _system_slug(db, campaign.game_system_id))


@router.delete("/{campaign_id}", status_code=204)
async def delete_campaign(
    campaign_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    campaign = await db.get(Campaign, campaign_id)
    if not campaign:
        raise HTTPException(404)
    if campaign.owner_id != user.id and not user.is_admin:
        raise HTTPException(403)
    await db.delete(campaign)
    await db.commit()


# ── Members ───────────────────────────────────────────────────────────────────

@router.get("/{campaign_id}/members")
async def list_members(
    campaign_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    campaign, _ = await _get_campaign_as_member(campaign_id, user, db)
    rows = (await db.execute(
        select(CampaignMember, User)
        .join(User, User.id == CampaignMember.user_id)
        .where(CampaignMember.campaign_id == campaign_id)
    )).all()
    out = [
        {
            "member_id": m.id,
            "user_id": u.id,
            "username": u.username,
            "display_name": u.display_name,
            "role": m.role,
            "character_name": m.character_name,
            "character_art_path": m.character_art_path,
            "character_sheet_url": m.character_sheet_url,
            "joined_at": m.joined_at.isoformat() if m.joined_at else None,
            "is_owner": False,
        }
        for m, u in rows
    ]
    # The owner is tracked on campaign.owner_id, not as a CampaignMember row —
    # surface them here so the roster is never mysteriously empty for the
    # person who just created the campaign.
    if not any(r["user_id"] == campaign.owner_id for r in out):
        owner = (await db.execute(
            select(User).where(User.id == campaign.owner_id)
        )).scalar_one_or_none()
        if owner:
            out.insert(0, {
                "member_id": None,
                "user_id": owner.id,
                "username": owner.username,
                "display_name": owner.display_name,
                "role": "owner",
                "character_name": None,
                "character_art_path": None,
                "character_sheet_url": None,
                "joined_at": campaign.created_at.isoformat() if campaign.created_at else None,
                "is_owner": True,
            })
    return out


@router.post("/{campaign_id}/members", status_code=201)
async def add_member(
    campaign_id: str,
    body: MemberAdd,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    await _get_campaign_as_member(campaign_id, user, db, require_gm=True)
    target = (await db.execute(select(User).where(User.username == body.username))).scalar_one_or_none()
    if not target:
        raise HTTPException(404, "User not found — they must have logged into Sanctum at least once")
    existing = (await db.execute(
        select(CampaignMember).where(
            CampaignMember.campaign_id == campaign_id, CampaignMember.user_id == target.id
        )
    )).scalar_one_or_none()
    if not existing:
        db.add(CampaignMember(campaign_id=campaign_id, user_id=target.id, role=body.role))
        await db.commit()
    return {"ok": True}


@router.patch("/{campaign_id}/members/me")
async def update_my_character(
    campaign_id: str,
    body: CharacterUpdate,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    await _get_campaign_as_member(campaign_id, user, db)
    member = await _my_member_row(campaign_id, user, db)
    if not member:
        raise HTTPException(403, "You don't have a character in this campaign")
    for field, value in body.model_dump(exclude_none=True).items():
        setattr(member, field, value)
    await db.commit()
    return {"ok": True}


@router.delete("/{campaign_id}/members/{target_user_id}", status_code=204)
async def remove_member(
    campaign_id: str,
    target_user_id: int,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    await _get_campaign_as_member(campaign_id, user, db, require_gm=True)
    member = (await db.execute(
        select(CampaignMember).where(
            CampaignMember.campaign_id == campaign_id, CampaignMember.user_id == target_user_id
        )
    )).scalar_one_or_none()
    if member:
        await db.delete(member)
        await db.commit()


# ── Invite links ──────────────────────────────────────────────────────────────

def _invite_out(inv: CampaignInvite) -> dict:
    now = datetime.now(timezone.utc)
    expired = inv.expires_at is not None and inv.expires_at <= now
    used_up = inv.max_uses is not None and inv.uses >= inv.max_uses
    return {
        "id": inv.id,
        "token": inv.token,
        "role": inv.role,
        "max_uses": inv.max_uses,
        "uses": inv.uses,
        "expires_at": inv.expires_at.isoformat() if inv.expires_at else None,
        "is_revoked": inv.is_revoked,
        "active": not (inv.is_revoked or expired or used_up),
        "created_at": inv.created_at.isoformat() if inv.created_at else None,
    }


@router.get("/{campaign_id}/invites")
async def list_invites(
    campaign_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    await _get_campaign_as_member(campaign_id, user, db, require_gm=True)
    rows = (await db.execute(
        select(CampaignInvite)
        .where(CampaignInvite.campaign_id == campaign_id)
        .order_by(CampaignInvite.created_at.desc())
    )).scalars().all()
    return [_invite_out(i) for i in rows]


@router.post("/{campaign_id}/invites", status_code=201)
async def create_invite(
    campaign_id: str,
    body: InviteCreate,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    await _get_campaign_as_member(campaign_id, user, db, require_gm=True)
    role = body.role if body.role in ("player", "gm") else "player"
    expires_at = None
    if body.expires_in_days and body.expires_in_days > 0:
        expires_at = datetime.now(timezone.utc) + timedelta(days=body.expires_in_days)
    max_uses = body.max_uses if (body.max_uses and body.max_uses > 0) else None
    invite = CampaignInvite(
        campaign_id=campaign_id,
        token=secrets.token_urlsafe(24),
        created_by_id=user.id,
        role=role,
        max_uses=max_uses,
        expires_at=expires_at,
    )
    db.add(invite)
    await db.commit()
    await db.refresh(invite)
    return _invite_out(invite)


@router.delete("/{campaign_id}/invites/{invite_id}", status_code=204)
async def revoke_invite(
    campaign_id: str,
    invite_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    await _get_campaign_as_member(campaign_id, user, db, require_gm=True)
    invite = await db.get(CampaignInvite, invite_id)
    if invite and invite.campaign_id == campaign_id:
        invite.is_revoked = True
        await db.commit()


# ── Session scheduling ────────────────────────────────────────────────────────

class PollCreate(BaseModel):
    title: str
    note: Optional[str] = None
    option_datetimes: list[datetime]  # candidate slots, ISO 8601


class PollRespond(BaseModel):
    responses: dict[str, str]  # {option_id: "yes" | "maybe" | "no"}


class PollUpdate(BaseModel):
    status: Optional[str] = None                 # "open" | "confirmed" | "closed"
    confirmed_option_id: Optional[str] = None


async def _poll_out(db: AsyncSession, poll: SessionPoll, user: User) -> dict:
    rows = (await db.execute(
        select(SessionPollResponse, User.display_name, User.username)
        .join(User, User.id == SessionPollResponse.user_id)
        .where(SessionPollResponse.poll_id == poll.id)
    )).all()
    by_option: dict[str, dict] = {}
    mine: dict[str, str] = {}
    for r, dname, uname in rows:
        who = dname or uname
        slot = by_option.setdefault(r.option_id, {"yes": [], "maybe": [], "no": []})
        if r.availability in slot:
            slot[r.availability].append(who)
        if r.user_id == user.id:
            mine[r.option_id] = r.availability
    options = [
        {
            "id": o["id"],
            "starts_at": o["starts_at"],
            "tally": by_option.get(o["id"], {"yes": [], "maybe": [], "no": []}),
        }
        for o in (poll.options or [])
    ]
    confirmed = next(
        (o for o in (poll.options or []) if o["id"] == poll.confirmed_option_id), None
    )
    return {
        "id": poll.id,
        "title": poll.title,
        "note": poll.note,
        "status": poll.status,
        "created_by_id": poll.created_by_id,
        "created_at": poll.created_at.isoformat() if poll.created_at else None,
        "options": options,
        "confirmed_option_id": poll.confirmed_option_id,
        "confirmed_starts_at": confirmed["starts_at"] if confirmed else None,
        "my_responses": mine,
    }


@router.get("/{campaign_id}/session-polls")
async def list_session_polls(
    campaign_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    await _get_campaign_as_member(campaign_id, user, db)
    polls = (await db.execute(
        select(SessionPoll)
        .where(SessionPoll.campaign_id == campaign_id)
        .order_by(SessionPoll.created_at.desc())
    )).scalars().all()
    return [await _poll_out(db, p, user) for p in polls]


@router.post("/{campaign_id}/session-polls", status_code=201)
async def create_session_poll(
    campaign_id: str,
    body: PollCreate,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    await _get_campaign_as_member(campaign_id, user, db, require_gm=True)
    slots = sorted(body.option_datetimes)
    if not slots:
        raise HTTPException(422, "Propose at least one time")
    poll = SessionPoll(
        campaign_id=campaign_id,
        created_by_id=user.id,
        title=body.title.strip() or "Session",
        note=(body.note or "").strip() or None,
        options=[{"id": str(uuid.uuid4()), "starts_at": s.isoformat()} for s in slots],
    )
    db.add(poll)
    await db.commit()
    await db.refresh(poll)
    return await _poll_out(db, poll, user)


@router.post("/{campaign_id}/session-polls/{poll_id}/respond")
async def respond_session_poll(
    campaign_id: str,
    poll_id: str,
    body: PollRespond,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    await _get_campaign_as_member(campaign_id, user, db)
    poll = await db.get(SessionPoll, poll_id)
    if not poll or poll.campaign_id != campaign_id:
        raise HTTPException(404, "Poll not found")
    valid_ids = {o["id"] for o in (poll.options or [])}
    existing = {
        r.option_id: r
        for r in (await db.execute(
            select(SessionPollResponse).where(
                SessionPollResponse.poll_id == poll_id,
                SessionPollResponse.user_id == user.id,
            )
        )).scalars().all()
    }
    for option_id, avail in body.responses.items():
        if option_id not in valid_ids or avail not in ("yes", "maybe", "no"):
            continue
        if option_id in existing:
            existing[option_id].availability = avail
        else:
            db.add(SessionPollResponse(
                poll_id=poll_id, option_id=option_id, user_id=user.id, availability=avail
            ))
    await db.commit()
    return await _poll_out(db, poll, user)


@router.patch("/{campaign_id}/session-polls/{poll_id}")
async def update_session_poll(
    campaign_id: str,
    poll_id: str,
    body: PollUpdate,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    await _get_campaign_as_member(campaign_id, user, db, require_gm=True)
    poll = await db.get(SessionPoll, poll_id)
    if not poll or poll.campaign_id != campaign_id:
        raise HTTPException(404, "Poll not found")
    if body.confirmed_option_id is not None:
        if body.confirmed_option_id and body.confirmed_option_id not in {
            o["id"] for o in (poll.options or [])
        }:
            raise HTTPException(422, "Unknown option")
        poll.confirmed_option_id = body.confirmed_option_id or None
        poll.status = "confirmed" if poll.confirmed_option_id else "open"
    if body.status is not None and body.status in ("open", "confirmed", "closed"):
        poll.status = body.status
        if body.status != "confirmed":
            poll.confirmed_option_id = None if body.status == "open" else poll.confirmed_option_id
    await db.commit()
    await db.refresh(poll)
    return await _poll_out(db, poll, user)


@router.delete("/{campaign_id}/session-polls/{poll_id}", status_code=204)
async def delete_session_poll(
    campaign_id: str,
    poll_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    await _get_campaign_as_member(campaign_id, user, db, require_gm=True)
    poll = await db.get(SessionPoll, poll_id)
    if poll and poll.campaign_id == campaign_id:
        await db.delete(poll)
        await db.commit()


# ── Session Notes ─────────────────────────────────────────────────────────────

def _note_out(n: SessionNote) -> dict:
    return {
        "id": n.id,
        "session_number": n.session_number,
        "title": n.title,
        "content": n.content,
        "is_gm_only": n.is_gm_only,
        "is_active": n.is_active,
        "xp_awarded": n.xp_awarded,
        "author_id": n.author_id,
        "created_at": n.created_at.isoformat() if n.created_at else None,
        "updated_at": n.updated_at.isoformat() if n.updated_at else None,
        "ended_at": n.ended_at.isoformat() if n.ended_at else None,
    }


@router.get("/{campaign_id}/notes")
async def list_notes(
    campaign_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    campaign, member = await _get_campaign_as_member(campaign_id, user, db)
    is_gm = _is_gm(campaign, member, user)

    stmt = select(SessionNote).where(SessionNote.campaign_id == campaign_id)
    if not is_gm:
        stmt = stmt.where(SessionNote.is_gm_only == False)
    stmt = stmt.order_by(SessionNote.session_number.desc(), SessionNote.created_at.desc())
    notes = (await db.execute(stmt)).scalars().all()
    return [_note_out(n) for n in notes]


# must be declared before /{note_id} so "active" isn't treated as a note ID
@router.get("/{campaign_id}/notes/active")
async def get_active_session(
    campaign_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    campaign, member = await _get_campaign_as_member(campaign_id, user, db)
    is_gm = _is_gm(campaign, member, user)

    note = (await db.execute(
        select(SessionNote).where(
            SessionNote.campaign_id == campaign_id,
            SessionNote.is_active == True,
        )
    )).scalar_one_or_none()

    if not note:
        return None

    result = {**_note_out(note), "private_notes": None, "my_notes": ""}

    if is_gm:
        gm_note = (await db.execute(
            select(GMSessionNote).where(GMSessionNote.session_id == note.id)
        )).scalar_one_or_none()
        result["private_notes"] = gm_note.private_notes if gm_note else ""

    if member:
        player_note = (await db.execute(
            select(PlayerSessionNote).where(
                PlayerSessionNote.session_id == note.id,
                PlayerSessionNote.member_id == member.id,
            )
        )).scalar_one_or_none()
        result["my_notes"] = player_note.content if player_note else ""

    return result


@router.get("/{campaign_id}/notes/{note_id}")
async def get_note(
    campaign_id: str,
    note_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    campaign, member = await _get_campaign_as_member(campaign_id, user, db)
    is_gm = _is_gm(campaign, member, user)
    note = await db.get(SessionNote, note_id)
    if not note or note.campaign_id != campaign_id:
        raise HTTPException(404)
    if note.is_gm_only and not is_gm:
        raise HTTPException(403)

    result = {**_note_out(note), "private_notes": None, "my_notes": ""}

    if is_gm:
        gm_note = (await db.execute(
            select(GMSessionNote).where(GMSessionNote.session_id == note_id)
        )).scalar_one_or_none()
        result["private_notes"] = gm_note.private_notes if gm_note else ""

    if member:
        player_note = (await db.execute(
            select(PlayerSessionNote).where(
                PlayerSessionNote.session_id == note_id,
                PlayerSessionNote.member_id == member.id,
            )
        )).scalar_one_or_none()
        result["my_notes"] = player_note.content if player_note else ""

    return result


@router.post("/{campaign_id}/notes", status_code=201)
async def create_note(
    campaign_id: str,
    body: NoteCreate,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    campaign, member = await _get_campaign_as_member(campaign_id, user, db, require_gm=True)

    # Check for orphaned active session
    existing_active = (await db.execute(
        select(SessionNote).where(
            SessionNote.campaign_id == campaign_id,
            SessionNote.is_active == True,
        )
    )).scalar_one_or_none()

    if existing_active:
        return JSONResponse(
            status_code=409,
            content={
                "detail": "active_session",
                "session": _note_out(existing_active),
            },
        )

    note = SessionNote(
        campaign_id=campaign_id,
        author_id=user.id,
        session_number=body.session_number,
        title=body.title,
        content=body.content,
        is_active=True,
    )
    db.add(note)
    await db.commit()
    await db.refresh(note)
    return _note_out(note)


@router.post("/{campaign_id}/notes/{note_id}/end")
async def end_session(
    campaign_id: str,
    note_id: str,
    body: EndSession,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    campaign, _ = await _get_campaign_as_member(campaign_id, user, db, require_gm=True)
    note = await db.get(SessionNote, note_id)
    if not note or note.campaign_id != campaign_id:
        raise HTTPException(404)
    if not note.is_active:
        raise HTTPException(400, "Session is not active")

    note.is_active = False
    note.xp_awarded = body.xp_awarded
    note.ended_at = datetime.now(timezone.utc)

    await db.commit()
    await db.refresh(note)
    return _note_out(note)


@router.patch("/{campaign_id}/notes/{note_id}")
async def update_note(
    campaign_id: str,
    note_id: str,
    body: NoteUpdate,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    campaign, member = await _get_campaign_as_member(campaign_id, user, db)
    note = await db.get(SessionNote, note_id)
    if not note or note.campaign_id != campaign_id:
        raise HTTPException(404)
    if note.author_id != user.id and campaign.owner_id != user.id:
        raise HTTPException(403)
    for field, value in body.model_dump(exclude_none=True).items():
        setattr(note, field, value)
    await db.commit()
    return {"ok": True}


@router.put("/{campaign_id}/notes/{note_id}/gm-notes")
async def upsert_gm_notes(
    campaign_id: str,
    note_id: str,
    body: GMNotesUpdate,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    campaign, member = await _get_campaign_as_member(campaign_id, user, db, require_gm=True)
    note = await db.get(SessionNote, note_id)
    if not note or note.campaign_id != campaign_id:
        raise HTTPException(404)

    gm_note = (await db.execute(
        select(GMSessionNote).where(GMSessionNote.session_id == note_id)
    )).scalar_one_or_none()

    if gm_note:
        if body.private_notes is not None:
            gm_note.private_notes = body.private_notes
    else:
        gm_note = GMSessionNote(session_id=note_id, private_notes=body.private_notes or "")
        db.add(gm_note)

    await db.commit()
    return {"ok": True}


@router.put("/{campaign_id}/notes/{note_id}/my-notes")
async def upsert_player_notes(
    campaign_id: str,
    note_id: str,
    body: PlayerNotesUpdate,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    campaign, member = await _get_campaign_as_member(campaign_id, user, db)
    if not member:
        raise HTTPException(403, "Campaign owner can use GM notes instead")
    note = await db.get(SessionNote, note_id)
    if not note or note.campaign_id != campaign_id:
        raise HTTPException(404)
    if note.is_gm_only and not _is_gm(campaign, member, user):
        raise HTTPException(403)

    player_note = (await db.execute(
        select(PlayerSessionNote).where(
            PlayerSessionNote.session_id == note_id,
            PlayerSessionNote.member_id == member.id,
        )
    )).scalar_one_or_none()

    if player_note:
        player_note.content = body.content
    else:
        player_note = PlayerSessionNote(session_id=note_id, member_id=member.id, content=body.content)
        db.add(player_note)

    await db.commit()
    return {"ok": True}


@router.delete("/{campaign_id}/notes/{note_id}", status_code=204)
async def delete_note(
    campaign_id: str,
    note_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    campaign, _ = await _get_campaign_as_member(campaign_id, user, db)
    note = await db.get(SessionNote, note_id)
    if not note or note.campaign_id != campaign_id:
        raise HTTPException(404)
    if note.author_id != user.id and campaign.owner_id != user.id and not user.is_admin:
        raise HTTPException(403)
    await db.delete(note)
    await db.commit()


# ── Wiki ──────────────────────────────────────────────────────────────────────

@router.get("/{campaign_id}/wiki")
async def list_wiki(
    campaign_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    campaign, member = await _get_campaign_as_member(campaign_id, user, db)
    is_gm = _is_gm(campaign, member, user)
    stmt = select(WikiPage).where(WikiPage.campaign_id == campaign_id)
    if not is_gm:
        stmt = stmt.where(WikiPage.is_gm_only == False)
    stmt = stmt.order_by(WikiPage.sort_order, WikiPage.title)
    pages = (await db.execute(stmt)).scalars().all()
    return [
        {
            "id": p.id,
            "title": p.title,
            "slug": p.slug,
            "content": p.content,
            "is_gm_only": p.is_gm_only,
            "parent_id": p.parent_id,
            "sort_order": p.sort_order,
            "author_id": p.author_id,
            "updated_at": p.updated_at.isoformat() if p.updated_at else None,
        }
        for p in pages
    ]


@router.post("/{campaign_id}/wiki", status_code=201)
async def create_wiki_page(
    campaign_id: str,
    body: WikiPageCreate,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    campaign, member = await _get_campaign_as_member(campaign_id, user, db)
    is_gm = _is_gm(campaign, member, user)
    if body.is_gm_only and not is_gm:
        raise HTTPException(403)
    page = WikiPage(
        campaign_id=campaign_id,
        author_id=user.id,
        slug=_slugify(body.title),
        **body.model_dump(),
    )
    db.add(page)
    await db.commit()
    await db.refresh(page)
    return {"id": page.id, "title": page.title, "slug": page.slug}


@router.patch("/{campaign_id}/wiki/{page_id}")
async def update_wiki_page(
    campaign_id: str,
    page_id: str,
    body: WikiPageUpdate,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    campaign, _ = await _get_campaign_as_member(campaign_id, user, db)
    page = await db.get(WikiPage, page_id)
    if not page or page.campaign_id != campaign_id:
        raise HTTPException(404)
    # exclude_unset (not exclude_none): parent_id must be nullable via PATCH
    # to move a page back to top level, which exclude_none would silently drop.
    updates = body.model_dump(exclude_unset=True)
    if "title" in updates:
        updates["slug"] = _slugify(updates["title"])
    for field, value in updates.items():
        setattr(page, field, value)
    await db.commit()
    return {"ok": True}


@router.delete("/{campaign_id}/wiki/{page_id}", status_code=204)
async def delete_wiki_page(
    campaign_id: str,
    page_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    campaign, _ = await _get_campaign_as_member(campaign_id, user, db)
    page = await db.get(WikiPage, page_id)
    if not page or page.campaign_id != campaign_id:
        raise HTTPException(404)
    if page.author_id != user.id and campaign.owner_id != user.id and not user.is_admin:
        raise HTTPException(403)
    await db.delete(page)
    await db.commit()


# ── Wiki templates ────────────────────────────────────────────────────────────

@router.get("/{campaign_id}/wiki-templates")
async def list_wiki_templates(
    campaign_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    await _get_campaign_as_member(campaign_id, user, db)
    templates = (await db.execute(
        select(WikiTemplate).where(WikiTemplate.campaign_id == campaign_id)
        .order_by(WikiTemplate.created_at)
    )).scalars().all()
    return [{"id": t.id, "name": t.name, "content": t.content} for t in templates]


@router.post("/{campaign_id}/wiki-templates", status_code=201)
async def create_wiki_template(
    campaign_id: str,
    body: WikiTemplateCreate,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    await _get_campaign_as_member(campaign_id, user, db)
    template = WikiTemplate(campaign_id=campaign_id, author_id=user.id, **body.model_dump())
    db.add(template)
    await db.commit()
    await db.refresh(template)
    return {"id": template.id, "name": template.name, "content": template.content}


@router.delete("/{campaign_id}/wiki-templates/{template_id}", status_code=204)
async def delete_wiki_template(
    campaign_id: str,
    template_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    campaign, _ = await _get_campaign_as_member(campaign_id, user, db)
    template = await db.get(WikiTemplate, template_id)
    if not template or template.campaign_id != campaign_id:
        raise HTTPException(404)
    # Same gate as delete_wiki_page: author, campaign owner, or admin.
    if template.author_id != user.id and campaign.owner_id != user.id and not user.is_admin:
        raise HTTPException(403)
    await db.delete(template)
    await db.commit()


# ── Wiki export / import ──────────────────────────────────────────────────────

def _wiki_page_out(p: WikiPage) -> dict:
    return {
        "id": p.id,
        "title": p.title,
        "slug": p.slug,
        "content": p.content,
        "is_gm_only": p.is_gm_only,
        "parent_id": p.parent_id,
        "sort_order": p.sort_order,
    }


@router.get("/{campaign_id}/wiki/export")
async def export_wiki(
    campaign_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Whole campaign wiki as one downloadable JSON file — the round-trip
    format for POST .../wiki/import. Same is_gm_only filtering as GET .../wiki
    so a player's export never contains pages they couldn't already see."""
    campaign, member = await _get_campaign_as_member(campaign_id, user, db)
    is_gm = _is_gm(campaign, member, user)
    stmt = select(WikiPage).where(WikiPage.campaign_id == campaign_id)
    if not is_gm:
        stmt = stmt.where(WikiPage.is_gm_only == False)
    pages = (await db.execute(stmt.order_by(WikiPage.sort_order, WikiPage.title))).scalars().all()
    payload = json.dumps([_wiki_page_out(p) for p in pages], indent=2, ensure_ascii=False)
    return Response(
        payload, media_type="application/json",
        headers={"Content-Disposition": f'attachment; filename="{campaign_id}-wiki.json"'},
    )


@router.get("/{campaign_id}/wiki/{page_id}/export")
async def export_wiki_page(
    campaign_id: str,
    page_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    campaign, member = await _get_campaign_as_member(campaign_id, user, db)
    is_gm = _is_gm(campaign, member, user)
    page = await db.get(WikiPage, page_id)
    if not page or page.campaign_id != campaign_id:
        raise HTTPException(404)
    if page.is_gm_only and not is_gm:
        raise HTTPException(404)
    return Response(
        page.content or "", media_type="text/markdown",
        headers={"Content-Disposition": f'attachment; filename="{page.slug or page.id}.md"'},
    )


@router.post("/{campaign_id}/wiki/import")
async def import_wiki(
    campaign_id: str,
    body: list[WikiPageImport],
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Bulk-create pages from a previously-exported wiki JSON array. GM-only —
    this is a setup/migration action, not routine page creation. Always
    creates new pages (never merges/updates by title match); hierarchy is
    reconstructed via a two-pass id remap since the exported ids almost
    certainly don't exist in this campaign (may not even be this campaign)."""
    await _get_campaign_as_member(campaign_id, user, db, require_gm=True)

    # Pass 1: create every page flat (parent_id=None), tracking the exported
    # page's own id -> the new ORM object so pass 2 can look up new ids.
    id_map: dict[str, WikiPage] = {}
    pages: list[tuple[WikiPage, Optional[str]]] = []  # (new page, original parent_id)
    for item in body:
        page = WikiPage(
            campaign_id=campaign_id,
            author_id=user.id,
            title=item.title,
            slug=_slugify(item.title),
            content=item.content,
            is_gm_only=item.is_gm_only,
            sort_order=item.sort_order,
            parent_id=None,
        )
        db.add(page)
        pages.append((page, item.parent_id))
        if item.id:
            id_map[item.id] = page
    await db.flush()  # assigns each page.id (needed before pass 2 can read them)

    # Pass 2: remap parent_id now that every new id exists. A referenced
    # old id that's missing from id_map (corrupt/partial input) just leaves
    # that page top-level rather than failing the whole import.
    for page, original_parent_id in pages:
        if original_parent_id and original_parent_id in id_map:
            page.parent_id = id_map[original_parent_id].id

    await db.commit()
    return {"imported": len(pages)}


@router.post("/{campaign_id}/wiki/import-markdown", status_code=201)
async def import_wiki_markdown(
    campaign_id: str,
    file: UploadFile = File(...),
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """One .md/.markdown file -> one new top-level wiki page. Open to any
    member, same as creating a page by hand."""
    await _get_campaign_as_member(campaign_id, user, db)
    suffix = Path(file.filename or "").suffix.lower()
    if suffix not in (".md", ".markdown"):
        raise HTTPException(400, "Only .md/.markdown files are supported")
    title = re.sub(r"[-_]+", " ", Path(file.filename).stem).strip() or "Untitled"
    content = (await file.read()).decode("utf-8", errors="replace")
    page = WikiPage(
        campaign_id=campaign_id, author_id=user.id, title=title,
        slug=_slugify(title), content=content, is_gm_only=False, parent_id=None,
    )
    db.add(page)
    await db.commit()
    await db.refresh(page)
    return {"id": page.id, "title": page.title, "slug": page.slug}


# ── Categories ────────────────────────────────────────────────────────────────

@router.get("/{campaign_id}/categories")
async def list_categories(
    campaign_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    await _get_campaign_as_member(campaign_id, user, db)
    cats = (await db.execute(
        select(CampaignCategory)
        .where(CampaignCategory.campaign_id == campaign_id)
        .order_by(CampaignCategory.sort_order, CampaignCategory.name)
    )).scalars().all()
    return [{"id": c.id, "name": c.name, "icon": c.icon, "sort_order": c.sort_order} for c in cats]


@router.post("/{campaign_id}/categories", status_code=201)
async def create_category(
    campaign_id: str,
    body: CategoryCreate,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    await _get_campaign_as_member(campaign_id, user, db, require_gm=True)
    cat = CampaignCategory(campaign_id=campaign_id, **body.model_dump())
    db.add(cat)
    await db.commit()
    await db.refresh(cat)
    return {"id": cat.id, "name": cat.name}


@router.delete("/{campaign_id}/categories/{category_id}", status_code=204)
async def delete_category(
    campaign_id: str,
    category_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    await _get_campaign_as_member(campaign_id, user, db, require_gm=True)
    cat = await db.get(CampaignCategory, category_id)
    if cat and cat.campaign_id == campaign_id:
        await db.delete(cat)
        await db.commit()


# ── Resources ─────────────────────────────────────────────────────────────────

@router.get("/{campaign_id}/resources")
async def list_resources(
    campaign_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    await _get_campaign_as_member(campaign_id, user, db)
    resources = (await db.execute(
        select(CampaignResource)
        .where(CampaignResource.campaign_id == campaign_id)
        .order_by(CampaignResource.sort_order, CampaignResource.created_at)
    )).scalars().all()
    return [
        {
            "id": r.id,
            "name": r.name,
            "resource_type": r.resource_type,
            "url": r.url,
            "book_id": r.book_id,
            "category_id": r.category_id,
            "sort_order": r.sort_order,
        }
        for r in resources
    ]


@router.post("/{campaign_id}/resources", status_code=201)
async def add_resource(
    campaign_id: str,
    body: ResourceCreate,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    await _get_campaign_as_member(campaign_id, user, db, require_gm=True)
    resource = CampaignResource(campaign_id=campaign_id, **body.model_dump())
    db.add(resource)
    await db.commit()
    await db.refresh(resource)
    return {"id": resource.id}


@router.delete("/{campaign_id}/resources/{resource_id}", status_code=204)
async def remove_resource(
    campaign_id: str,
    resource_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    await _get_campaign_as_member(campaign_id, user, db, require_gm=True)
    resource = await db.get(CampaignResource, resource_id)
    if resource and resource.campaign_id == campaign_id:
        await db.delete(resource)
        await db.commit()


# ── Files ─────────────────────────────────────────────────────────────────────

@router.get("/{campaign_id}/files")
async def list_files(
    campaign_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    await _get_campaign_as_member(campaign_id, user, db)
    files = (await db.execute(
        select(CampaignFile)
        .where(CampaignFile.campaign_id == campaign_id)
        .order_by(CampaignFile.created_at.desc())
    )).scalars().all()
    return [
        {
            "id": f.id,
            "filename": f.filename,
            "mime_type": f.mime_type,
            "size_bytes": f.size_bytes,
            "is_image": f.is_image,
            "created_at": f.created_at.isoformat() if f.created_at else None,
        }
        for f in files
    ]


@router.post("/{campaign_id}/files", status_code=201)
async def upload_file(
    campaign_id: str,
    file: UploadFile = File(...),
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    await _get_campaign_as_member(campaign_id, user, db)
    dest_dir = Path(settings.campaign_files_path) / campaign_id
    dest_dir.mkdir(parents=True, exist_ok=True)
    safe_name = f"{uuid.uuid4().hex}_{Path(file.filename).name}"
    dest = dest_dir / safe_name
    content = await file.read()
    dest.write_bytes(content)
    mime = file.content_type or mimetypes.guess_type(file.filename)[0] or "application/octet-stream"
    cf = CampaignFile(
        campaign_id=campaign_id,
        stored_path=str(dest.relative_to(settings.campaign_files_path)),
        filename=file.filename,
        mime_type=mime,
        size_bytes=len(content),
        is_image=mime.startswith("image/"),
        uploaded_by_id=user.id,
    )
    db.add(cf)
    await db.commit()
    await db.refresh(cf)
    return {"id": cf.id, "filename": cf.filename}


@router.get("/{campaign_id}/files/{file_id}/download")
async def download_file(
    campaign_id: str,
    file_id: str,
    db: AsyncSession = Depends(get_db),
    _: User = Depends(get_current_user),
):
    cf = await db.get(CampaignFile, file_id)
    if not cf or cf.campaign_id != campaign_id:
        raise HTTPException(404)
    path = Path(settings.campaign_files_path) / cf.stored_path
    if not path.exists():
        raise HTTPException(404, "File not found on disk")
    from fastapi.responses import FileResponse
    return FileResponse(path, media_type=cf.mime_type, filename=cf.filename)


@router.delete("/{campaign_id}/files/{file_id}", status_code=204)
async def delete_file(
    campaign_id: str,
    file_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    await _get_campaign_as_member(campaign_id, user, db, require_gm=True)
    cf = await db.get(CampaignFile, file_id)
    if cf and cf.campaign_id == campaign_id:
        path = Path(settings.campaign_files_path) / cf.stored_path
        if path.exists():
            path.unlink()
        await db.delete(cf)
        await db.commit()


# ── Banner (GM upload) ──────────────────────────────────────────────────────

@router.post("/{campaign_id}/banner", status_code=201)
async def upload_banner(
    campaign_id: str,
    file: UploadFile = File(...),
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    campaign, _ = await _get_campaign_as_member(campaign_id, user, db, require_gm=True)
    dest_dir = Path(settings.campaign_files_path) / campaign_id
    dest_dir.mkdir(parents=True, exist_ok=True)
    # One current banner, not an accumulating pile of every upload — clear
    # whatever's there (regardless of its extension) before writing the new one.
    for old in dest_dir.glob("banner.*"):
        old.unlink()
    ext = Path(file.filename).suffix or ""
    dest = dest_dir / f"banner{ext}"
    dest.write_bytes(await file.read())
    campaign.banner_url = f"/api/campaigns/{campaign_id}/banner"
    await db.commit()
    return {"banner_url": campaign.banner_url}


@router.get("/{campaign_id}/banner")
async def get_banner(
    campaign_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    await _get_campaign_as_member(campaign_id, user, db)
    dest_dir = Path(settings.campaign_files_path) / campaign_id
    matches = list(dest_dir.glob("banner.*")) if dest_dir.exists() else []
    if not matches:
        raise HTTPException(404, "No banner uploaded")
    from fastapi.responses import FileResponse
    mime = mimetypes.guess_type(matches[0].name)[0] or "application/octet-stream"
    return FileResponse(matches[0], media_type=mime)


# ── Character sheet (player upload) ─────────────────────────────────────────
# Self-service, same shape as PATCH /{campaign_id}/members/me above — a player
# only ever uploads their own sheet. GMs/party members can still view any
# member's sheet via the member_id-scoped GET below.

@router.post("/{campaign_id}/members/me/character-sheet", status_code=201)
async def upload_my_character_sheet(
    campaign_id: str,
    file: UploadFile = File(...),
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    await _get_campaign_as_member(campaign_id, user, db)
    member = await _my_member_row(campaign_id, user, db)
    if not member:
        raise HTTPException(403, "You don't have a character in this campaign")
    dest_dir = Path(settings.campaign_files_path) / campaign_id / "character_sheets"
    dest_dir.mkdir(parents=True, exist_ok=True)
    for old in dest_dir.glob(f"{member.id}.*"):
        old.unlink()
    ext = Path(file.filename).suffix or ""
    dest = dest_dir / f"{member.id}{ext}"
    dest.write_bytes(await file.read())
    member.character_sheet_url = f"/api/campaigns/{campaign_id}/members/{member.id}/character-sheet"
    await db.commit()
    return {"character_sheet_url": member.character_sheet_url}


@router.get("/{campaign_id}/members/{member_id}/character-sheet")
async def get_character_sheet(
    campaign_id: str,
    member_id: int,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    await _get_campaign_as_member(campaign_id, user, db)
    target = await db.get(CampaignMember, member_id)
    if not target or target.campaign_id != campaign_id:
        raise HTTPException(404)
    dest_dir = Path(settings.campaign_files_path) / campaign_id / "character_sheets"
    matches = list(dest_dir.glob(f"{member_id}.*")) if dest_dir.exists() else []
    if not matches:
        raise HTTPException(404, "No character sheet uploaded")
    from fastapi.responses import FileResponse
    mime = mimetypes.guess_type(matches[0].name)[0] or "application/octet-stream"
    name = f"{target.character_name or 'character'}{matches[0].suffix}"
    return FileResponse(matches[0], media_type=mime, filename=name)


# ── Session Room (live play) — system-agnostic ──────────────────────────────
#
# The session log (FuzionSessionLog — legacy name, generic model) records
# chat / roll / system / journal entries. `session_active` +
# `session_started_at` live in campaign.settings and mark the cutoff so the
# Session Room only shows the current session's activity. A game system can
# layer a richer "focused" room on top (Fuzion does) but these endpoints and
# the generic room work for any campaign.

class LogEntryCreate(BaseModel):
    kind: str = "chat"          # chat | roll | system | journal
    payload: dict = {}


@router.post("/{campaign_id}/session/start")
async def start_session(
    campaign_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    campaign, member = await _get_campaign_as_member(campaign_id, user, db)
    if not _is_gm(campaign, member, user):
        raise HTTPException(403, "GM only")
    # Insert the "Session started" marker first and take the cutoff from its own
    # DB-assigned created_at. A separate datetime.now() would land a hair AFTER
    # the row's transaction timestamp, so the `created_at >= cutoff` filter in
    # GET /log?current_only would drop the marker itself from the feed.
    marker = FuzionSessionLog(
        campaign_id=campaign_id, author_name=user.display_name or user.username,
        kind="system", payload={"text": "Session started"},
    )
    db.add(marker)
    await db.flush()
    await db.refresh(marker, ["created_at"])
    started_at = (marker.created_at or datetime.now(timezone.utc)).isoformat()
    s = dict(campaign.settings or {})
    s["session_active"] = True
    s["session_started_at"] = started_at
    campaign.settings = s
    flag_modified(campaign, "settings")
    await db.commit()
    return {"session_active": True, "session_started_at": started_at}


@router.get("/{campaign_id}/session-state")
async def get_session_state(
    campaign_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Cheap poll target so a player on the game page sees a session go live."""
    campaign, _ = await _get_campaign_as_member(campaign_id, user, db)
    s = campaign.settings or {}
    return {
        "session_active": s.get("session_active") is True,
        "session_started_at": s.get("session_started_at"),
        "sessions_completed": int(s.get("sessions_completed") or 0),
    }


@router.post("/{campaign_id}/session/end")
async def end_session(
    campaign_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    campaign, member = await _get_campaign_as_member(campaign_id, user, db)
    if not _is_gm(campaign, member, user):
        raise HTTPException(403, "GM only")
    s = dict(campaign.settings or {})
    s["session_active"] = False
    s["sessions_completed"] = int(s.get("sessions_completed") or 0) + 1
    campaign.settings = s
    flag_modified(campaign, "settings")
    db.add(FuzionSessionLog(
        campaign_id=campaign_id, author_name=user.display_name or user.username,
        kind="system", payload={"text": "Session ended"},
    ))
    await db.commit()
    return {"session_active": False, "sessions_completed": s["sessions_completed"]}


@router.get("/{campaign_id}/log")
async def get_session_log(
    campaign_id: str,
    after: Optional[str] = None,
    limit: int = 200,
    current_only: bool = False,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    campaign, member = await _get_campaign_as_member(campaign_id, user, db)
    is_gm = _is_gm(campaign, member, user)

    stmt = (select(FuzionSessionLog)
            .where(FuzionSessionLog.campaign_id == campaign_id)
            .order_by(FuzionSessionLog.created_at.desc())
            .limit(min(limit, 500)))

    if current_only:
        cutoff = (campaign.settings or {}).get("session_started_at")
        if not cutoff:
            rows_sys = (await db.execute(
                select(FuzionSessionLog)
                .where(FuzionSessionLog.campaign_id == campaign_id,
                       FuzionSessionLog.kind == "system")
                .order_by(FuzionSessionLog.created_at.desc())
            )).scalars().all()
            for r in rows_sys:
                if (r.payload or {}).get("text") == "Session started":
                    cutoff = r.created_at.isoformat() if r.created_at else None
                    break
        if cutoff:
            try:
                stmt = stmt.where(FuzionSessionLog.created_at >= datetime.fromisoformat(cutoff))
            except (ValueError, TypeError):
                pass

    rows = (await db.execute(stmt)).scalars().all()
    rows.reverse()

    out = []
    for r in rows:
        p = r.payload or {}
        # Private rolls are visible only to their author and the GM.
        if (not is_gm and r.kind == "roll" and p.get("private")
                and p.get("author_id") != user.id):
            continue
        out.append({
            "id": r.id, "author_name": r.author_name, "kind": r.kind,
            "source": r.source, "payload": p,
            "created_at": r.created_at.isoformat() if r.created_at else None,
        })
    return out


@router.post("/{campaign_id}/log", status_code=201)
async def post_session_log(
    campaign_id: str,
    body: LogEntryCreate,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    await _get_campaign_as_member(campaign_id, user, db)
    if body.kind not in ("chat", "roll", "system", "journal"):
        raise HTTPException(422, "kind must be chat|roll|system|journal")
    payload = dict(body.payload or {})
    payload["author_id"] = user.id   # for private-roll filtering + attribution
    row = FuzionSessionLog(
        campaign_id=campaign_id,
        author_name=user.display_name or user.username,
        kind=body.kind, source="app", payload=payload,
    )
    db.add(row)
    await db.commit()
    await db.refresh(row)
    return {"id": row.id, "created_at": row.created_at.isoformat() if row.created_at else None}
