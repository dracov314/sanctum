import asyncio
import io
import mimetypes
from pathlib import Path
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func, cast
from sqlalchemy.dialects.postgresql import JSONB
from ..database import get_db
from ..models import Map, Token, Favorite, User
from ..auth import get_current_user, require_admin
from ..config import settings
from ..pdf_render import render_pdf_page, pdf_page_count


class TagsUpdate(BaseModel):
    tags: list[str]


def _clean_tags(tags: list[str]) -> list[str]:
    seen, clean = set(), []
    for t in tags:
        t = t.strip()
        if t and t.lower() not in seen:
            seen.add(t.lower())
            clean.append(t)
    return clean

router = APIRouter(prefix="/assets", tags=["assets"])

IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp", ".tiff", ".svg"}


def _map_out(m: Map, is_favorited: bool = False) -> dict:
    return {
        "id": m.id,
        "filename": m.filename,
        "filepath": m.filepath,
        "description": m.description,
        "tags": m.tags or [],
        "map_type": m.map_type,
        "grid_size": m.grid_size,
        "file_size": m.file_size,
        "folder": m.folder,
        "mime_type": m.mime_type,
        "page_count": m.page_count,
        "is_favorited": is_favorited,
    }


def _token_out(t: Token, is_favorited: bool = False) -> dict:
    return {
        "id": t.id,
        "filename": t.filename,
        "filepath": t.filepath,
        "description": t.description,
        "tags": t.tags or [],
        "is_explicit": t.is_explicit,
        "file_size": t.file_size,
        "folder": t.folder,
        "is_favorited": is_favorited,
    }


async def _favorited_ids(db: AsyncSession, user: User, item_type: str, ids: list[str]) -> set[str]:
    if not ids:
        return set()
    result = await db.execute(
        select(Favorite.item_id).where(
            Favorite.user_id == user.id,
            Favorite.item_type == item_type,
            Favorite.item_id.in_(ids),
        )
    )
    return {row[0] for row in result}


# ── Maps ──────────────────────────────────────────────────────────────────────

@router.get("/maps/folders")
async def list_map_folders(
    db: AsyncSession = Depends(get_db),
    _: User = Depends(get_current_user),
):
    rows = (await db.execute(
        select(Map.folder).distinct().where(Map.folder.isnot(None)).order_by(Map.folder)
    )).scalars().all()
    return rows


@router.get("/maps/tags")
async def list_map_tags(db: AsyncSession = Depends(get_db), _: User = Depends(get_current_user)):
    rows = (await db.execute(
        select(func.jsonb_array_elements_text(cast(Map.tags, JSONB)))
        .where(func.json_typeof(Map.tags) == "array")
        .distinct()
    )).all()
    return sorted({r[0] for r in rows}, key=str.lower)


@router.patch("/maps/{map_id}/tags")
async def update_map_tags(
    map_id: str,
    body: TagsUpdate,
    db: AsyncSession = Depends(get_db),
    _: User = Depends(get_current_user),
):
    m = await db.get(Map, map_id)
    if not m:
        raise HTTPException(404)
    m.tags = _clean_tags(body.tags)
    await db.commit()
    return {"tags": m.tags}


@router.get("/maps")
async def list_maps(
    folder: Optional[str] = Query(None),
    q: Optional[str] = Query(None),
    tag: Optional[str] = Query(None),
    favorites_only: bool = Query(False),
    page: int = Query(1, ge=1),
    page_size: int = Query(40, ge=1, le=200),
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    stmt = select(Map)
    if folder is not None:
        stmt = stmt.where(Map.folder == folder)
    if q:
        stmt = stmt.where(Map.filename.ilike(f"%{q}%"))
    if tag:
        stmt = stmt.where(cast(Map.tags, JSONB).contains([tag]))
    if favorites_only:
        stmt = stmt.where(Map.id.in_(
            select(Favorite.item_id).where(Favorite.user_id == user.id, Favorite.item_type == "map")
        ))
    total = (await db.execute(select(func.count()).select_from(stmt.subquery()))).scalar_one()
    stmt = stmt.order_by(Map.folder, Map.filename).offset((page - 1) * page_size).limit(page_size)
    maps = (await db.execute(stmt)).scalars().all()
    favorited = await _favorited_ids(db, user, "map", [m.id for m in maps])
    return {"total": total, "page": page, "page_size": page_size,
            "items": [_map_out(m, m.id in favorited) for m in maps]}


@router.get("/maps/{map_id}/file")
async def serve_map(
    map_id: str,
    db: AsyncSession = Depends(get_db),
    _: User = Depends(get_current_user),
):
    m = await db.get(Map, map_id)
    if not m:
        raise HTTPException(404)
    path = Path(settings.library_path) / "maps" / m.filepath
    if not path.exists():
        raise HTTPException(404, "File not found on disk")
    media_type = mimetypes.guess_type(str(path))[0] or "application/octet-stream"
    return FileResponse(path, media_type=media_type)


@router.get("/maps/{map_id}/page/{page_num}")
async def serve_map_page(
    map_id: str,
    page_num: int,
    width: int = Query(1600, ge=200, le=3000),
    db: AsyncSession = Depends(get_db),
    _: User = Depends(get_current_user),
):
    """A rendered page of a PDF map pack (1-indexed), WebP, disk-cached."""
    m = await db.get(Map, map_id)
    if not m or not m.page_count:
        raise HTTPException(404)
    path = Path(settings.library_path) / "maps" / m.filepath
    if not path.exists():
        raise HTTPException(404, "File not found on disk")
    try:
        img_bytes = await asyncio.to_thread(render_pdf_page, path, page_num, width)
    except ValueError:
        raise HTTPException(400, f"Page must be between 1 and {m.page_count}")
    return StreamingResponse(
        io.BytesIO(img_bytes),
        media_type="image/webp",
        headers={"Cache-Control": "public, max-age=86400"},
    )


# ── Tokens ────────────────────────────────────────────────────────────────────

@router.get("/tokens/folders")
async def list_token_folders(
    db: AsyncSession = Depends(get_db),
    _: User = Depends(get_current_user),
):
    rows = (await db.execute(
        select(Token.folder).distinct().where(Token.folder.isnot(None)).order_by(Token.folder)
    )).scalars().all()
    return rows


@router.get("/tokens/tags")
async def list_token_tags(db: AsyncSession = Depends(get_db), _: User = Depends(get_current_user)):
    rows = (await db.execute(
        select(func.jsonb_array_elements_text(cast(Token.tags, JSONB)))
        .where(func.json_typeof(Token.tags) == "array")
        .distinct()
    )).all()
    return sorted({r[0] for r in rows}, key=str.lower)


@router.patch("/tokens/{token_id}/tags")
async def update_token_tags(
    token_id: str,
    body: TagsUpdate,
    db: AsyncSession = Depends(get_db),
    _: User = Depends(get_current_user),
):
    t = await db.get(Token, token_id)
    if not t:
        raise HTTPException(404)
    t.tags = _clean_tags(body.tags)
    await db.commit()
    return {"tags": t.tags}


@router.get("/tokens")
async def list_tokens(
    folder: Optional[str] = Query(None),
    q: Optional[str] = Query(None),
    tag: Optional[str] = Query(None),
    favorites_only: bool = Query(False),
    page: int = Query(1, ge=1),
    page_size: int = Query(40, ge=1, le=200),
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    stmt = select(Token)
    if not user.allow_explicit:
        stmt = stmt.where(Token.is_explicit == False)
    if folder is not None:
        stmt = stmt.where(Token.folder == folder)
    if q:
        stmt = stmt.where(Token.filename.ilike(f"%{q}%"))
    if tag:
        stmt = stmt.where(cast(Token.tags, JSONB).contains([tag]))
    if favorites_only:
        stmt = stmt.where(Token.id.in_(
            select(Favorite.item_id).where(Favorite.user_id == user.id, Favorite.item_type == "token")
        ))
    total = (await db.execute(select(func.count()).select_from(stmt.subquery()))).scalar_one()
    stmt = stmt.order_by(Token.folder, Token.filename).offset((page - 1) * page_size).limit(page_size)
    tokens = (await db.execute(stmt)).scalars().all()
    favorited = await _favorited_ids(db, user, "token", [t.id for t in tokens])
    return {"total": total, "page": page, "page_size": page_size,
            "items": [_token_out(t, t.id in favorited) for t in tokens]}


@router.get("/tokens/{token_id}/file")
async def serve_token(
    token_id: str,
    db: AsyncSession = Depends(get_db),
    _: User = Depends(get_current_user),
):
    t = await db.get(Token, token_id)
    if not t:
        raise HTTPException(404)
    path = Path(settings.library_path) / "tokens" / t.filepath
    if not path.exists():
        raise HTTPException(404, "File not found on disk")
    media_type = mimetypes.guess_type(str(path))[0] or "application/octet-stream"
    return FileResponse(path, media_type=media_type)


# ── Scan (admin) ──────────────────────────────────────────────────────────────

@router.post("/scan", dependencies=[Depends(require_admin)])
async def scan_assets(db: AsyncSession = Depends(get_db)):
    """Walk the library maps/ and tokens/ directories and index any image files found."""
    maps_root = Path(settings.library_path) / "maps"
    tokens_root = Path(settings.library_path) / "tokens"
    added = {"maps": 0, "tokens": 0}

    if maps_root.exists():
        for p in sorted(maps_root.rglob("*")):
            is_pdf = p.suffix.lower() == ".pdf"
            if not (p.is_file() and (p.suffix.lower() in IMAGE_EXTS or is_pdf)):
                continue
            rel = p.relative_to(maps_root)
            folder = str(rel.parent) if rel.parent != Path(".") else None
            filepath = str(rel)
            existing = (await db.execute(select(Map).where(Map.filepath == filepath))).scalar_one_or_none()
            if existing:
                continue
            page_count = None
            mime = mimetypes.guess_type(p.name)[0]
            if is_pdf:
                mime = "application/pdf"
                try:
                    page_count = pdf_page_count(p)
                except Exception:
                    continue  # unreadable PDF — skip rather than index a broken row
            db.add(Map(
                filename=p.name,
                filepath=filepath,
                file_size=p.stat().st_size,
                folder=folder,
                mime_type=mime,
                page_count=page_count,
                tags=[],
            ))
            added["maps"] += 1

    if tokens_root.exists():
        for p in sorted(tokens_root.rglob("*")):
            if p.is_file() and p.suffix.lower() in IMAGE_EXTS:
                rel = p.relative_to(tokens_root)
                folder = str(rel.parent) if rel.parent != Path(".") else None
                filepath = str(rel)
                existing = (await db.execute(select(Token).where(Token.filepath == filepath))).scalar_one_or_none()
                if not existing:
                    db.add(Token(
                        filename=p.name,
                        filepath=filepath,
                        file_size=p.stat().st_size,
                        folder=folder,
                        tags=[],
                    ))
                    added["tokens"] += 1

    await db.commit()
    return {"added": added}
