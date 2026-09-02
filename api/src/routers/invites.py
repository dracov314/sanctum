"""Invite-link acceptance — the public/token-scoped half of guest access.

GM-facing invite management (create / list / revoke) lives in
routers/campaigns.py under /campaigns/{id}/invites. This router is the part a
recipient hits: an unauthenticated preview and an authenticated accept.
"""
from datetime import datetime, timezone
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from ..database import get_db
from ..models import Campaign, CampaignInvite, CampaignMember, User
from ..auth import get_current_user

router = APIRouter(prefix="/invites", tags=["invites"])


async def evaluate_invite(
    db: AsyncSession, token: str
) -> tuple[Optional[CampaignInvite], Optional[Campaign], Optional[str]]:
    """Returns (invite, campaign, reason). reason is None when the invite is
    usable; otherwise a short human string ('expired', 'revoked', ...)."""
    invite = (await db.execute(
        select(CampaignInvite).where(CampaignInvite.token == token)
    )).scalar_one_or_none()
    if not invite:
        return None, None, "not_found"
    campaign = await db.get(Campaign, invite.campaign_id)
    if not campaign:
        return invite, None, "not_found"
    if invite.is_revoked:
        return invite, campaign, "revoked"
    if invite.expires_at and invite.expires_at <= datetime.now(timezone.utc):
        return invite, campaign, "expired"
    if invite.max_uses is not None and invite.uses >= invite.max_uses:
        return invite, campaign, "used_up"
    return invite, campaign, None


@router.get("/{token}")
async def preview_invite(token: str, db: AsyncSession = Depends(get_db)):
    """Unauthenticated — the recipient sees what they're joining before they
    sign in. Only the campaign name + inviter display name are disclosed."""
    invite, campaign, reason = await evaluate_invite(db, token)
    if not invite or not campaign:
        raise HTTPException(status_code=404, detail="This invite link is not valid")
    inviter = None
    if invite.created_by_id:
        u = await db.get(User, invite.created_by_id)
        inviter = (u.display_name or u.username) if u else None
    return {
        "campaign_id": campaign.id,
        "campaign_name": campaign.name,
        "inviter_name": inviter,
        "role": invite.role,
        "valid": reason is None,
        "reason": reason,
    }


@router.post("/{token}/accept")
async def accept_invite(
    token: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    invite, campaign, reason = await evaluate_invite(db, token)
    if not invite or not campaign:
        raise HTTPException(status_code=404, detail="This invite link is not valid")
    if reason:
        raise HTTPException(status_code=410, detail=f"This invite link is no longer usable ({reason})")

    if campaign.owner_id == user.id:
        return {"campaign_id": campaign.id, "already_member": True}

    existing = (await db.execute(
        select(CampaignMember).where(
            CampaignMember.campaign_id == campaign.id,
            CampaignMember.user_id == user.id,
        )
    )).scalar_one_or_none()

    if existing:
        already = True
    else:
        db.add(CampaignMember(campaign_id=campaign.id, user_id=user.id, role=invite.role))
        invite.uses += 1
        already = False

    await db.commit()
    return {"campaign_id": campaign.id, "already_member": already}
