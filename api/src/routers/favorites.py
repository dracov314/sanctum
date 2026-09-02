from typing import Literal
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from ..database import get_db
from ..models import Favorite, User
from ..auth import get_current_user

router = APIRouter(prefix="/favorites", tags=["favorites"])

VALID_ITEM_TYPES = {"book", "map", "token"}


class FavoriteCreate(BaseModel):
    item_type: str
    item_id: str


@router.get("")
async def list_favorites(
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    favs = (await db.execute(
        select(Favorite)
        .where(Favorite.user_id == user.id)
        .order_by(Favorite.created_at.desc())
    )).scalars().all()
    return [
        {
            "id": f.id,
            "item_type": f.item_type,
            "item_id": f.item_id,
            "created_at": f.created_at.isoformat() if f.created_at else None,
        }
        for f in favs
    ]


@router.post("", status_code=201)
async def add_favorite(
    body: FavoriteCreate,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    if body.item_type not in VALID_ITEM_TYPES:
        raise HTTPException(400, f"item_type must be one of {VALID_ITEM_TYPES}")
    existing = (await db.execute(
        select(Favorite).where(
            Favorite.user_id == user.id,
            Favorite.item_type == body.item_type,
            Favorite.item_id == body.item_id,
        )
    )).scalar_one_or_none()
    if not existing:
        db.add(Favorite(user_id=user.id, item_type=body.item_type, item_id=body.item_id))
        await db.commit()
    return {"ok": True}


@router.delete("/{item_type}/{item_id}", status_code=204)
async def remove_favorite(
    item_type: str,
    item_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    fav = (await db.execute(
        select(Favorite).where(
            Favorite.user_id == user.id,
            Favorite.item_type == item_type,
            Favorite.item_id == item_id,
        )
    )).scalar_one_or_none()
    if fav:
        await db.delete(fav)
        await db.commit()
