import asyncio
import hashlib
import io
import re
import mimetypes
import zipfile
from pathlib import Path
from typing import Optional
import fitz  # PyMuPDF
from PIL import Image
from fastapi import APIRouter, Depends, HTTPException, Query, UploadFile, File, Form
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func, cast
from sqlalchemy.dialects.postgresql import JSONB
from ..database import get_db
from ..models import Book, BookPage, GameSystem, Bookmark, Favorite, User, Map, Token
from ..auth import get_current_user, require_admin
from ..config import settings
from .. import book_indexing as indexing
from .. import library_scan
from ..pdf_render import render_pdf_page, get_pdf_page_words

router = APIRouter(prefix="/library", tags=["library"])


def _thumb_slug(filename: str) -> str:
    """Thumbnail filename convention: slugify the filename stem."""
    stem = Path(filename).stem
    slug = stem.lower().strip()
    slug = re.sub(r"[^\w\s-]", "", slug)
    slug = re.sub(r"[\s_-]+", "-", slug)
    return slug.strip("-")


class BookmarkCreate(BaseModel):
    page_number: Optional[int] = None
    label: Optional[str] = None
    notes: Optional[str] = None
    selected_text: Optional[str] = None


def _book_out(book: Book, is_bookmarked: bool = False, is_favorited: bool = False) -> dict:
    return {
        "id": book.id,
        "title": book.title,
        "mime_type": book.mime_type,
        "game_system_id": book.game_system_id,
        "category": book.category,
        "description": book.description,
        "authors": book.authors,
        "publisher": book.publisher,
        "publisher_url": book.publisher_url,
        "isbn": book.isbn,
        "license": book.license,
        "year": book.year,
        "file_size": book.file_size,
        "page_count": book.page_count,
        "has_thumbnail": book.has_thumbnail,
        "tags": book.tags,
        "is_explicit": book.is_explicit,
        "is_bookmarked": is_bookmarked,
        "is_favorited": is_favorited,
        "indexed": book.indexed,
        "ocr_pending": book.ocr_pending,
        "index_error": book.index_error or None,
        "is_missing": book.is_missing,
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


def _bookmark_out(bm: Bookmark) -> dict:
    return {
        "id": bm.id,
        "book_id": bm.book_id,
        "page_number": bm.page_number,
        "label": bm.label,
        "notes": bm.notes,
        "selected_text": bm.selected_text,
        "created_at": bm.created_at.isoformat() if bm.created_at else None,
    }


@router.get("/systems")
async def list_systems(db: AsyncSession = Depends(get_db), _: User = Depends(get_current_user)):
    # Correlated subquery: first core book (alphabetically) for each system
    cover_sq = (
        select(Book.id)
        .where(Book.game_system_id == GameSystem.id, Book.category == "core")
        .order_by(Book.title)
        .limit(1)
        .correlate(GameSystem)
        .scalar_subquery()
    )
    rows = (await db.execute(
        select(GameSystem, func.count(Book.id).label("book_count"), cover_sq.label("cover_book_id"))
        .outerjoin(Book, Book.game_system_id == GameSystem.id)
        .group_by(GameSystem.id)
        .order_by(GameSystem.name)
    )).all()
    return [
        {
            "id": s.id,
            "name": s.name,
            "slug": s.slug,
            "genre": s.genre,
            "character_builder_url": s.character_builder_url,
            "parent_id": s.parent_id,
            "book_count": count,
            "cover_book_id": cover_id,
        }
        for s, count, cover_id in rows
    ]


class GameSystemUpdate(BaseModel):
    name: Optional[str] = None
    genre: Optional[str] = None
    character_builder_url: Optional[str] = None
    parent_id: Optional[str] = None


@router.patch("/systems/{system_id}", dependencies=[Depends(require_admin)])
async def update_system(
    system_id: str,
    body: GameSystemUpdate,
    db: AsyncSession = Depends(get_db),
):
    system = await db.get(GameSystem, system_id)
    if not system:
        raise HTTPException(404, "Game system not found")
    # exclude_unset (not exclude_none): a blanked-out genre/URL field should
    # be able to clear back to null, same reasoning as the wiki PATCH fix.
    updates = body.model_dump(exclude_unset=True)
    if "name" in updates and not (updates["name"] or "").strip():
        raise HTTPException(422, "Name cannot be empty")
    if updates.get("parent_id") == system_id:
        raise HTTPException(422, "A system can't be its own parent")
    # Deliberately does not touch `slug` (the folder-derived scan identity —
    # see library_scan.py's slug-or-name match) so a rename here survives the
    # next library scan instead of spawning a duplicate system row.
    for field, value in updates.items():
        setattr(system, field, value)
    await db.commit()
    return {"ok": True}


def _safe_name(name: str) -> str:
    return re.sub(r'[\\/:*?"<>|]', "-", name).strip()


class _ZipBuffer:
    """Unseekable write sink for zipfile; drained between members."""
    def __init__(self):
        self._buf = bytearray()
        self._pos = 0

    def write(self, data):
        self._buf += data
        self._pos += len(data)
        return len(data)

    def tell(self):
        return self._pos

    def flush(self):
        pass

    def drain(self) -> bytes:
        data = bytes(self._buf)
        self._buf.clear()
        return data


def _zip_stream(files: list[tuple[Path, str]]):
    buf = _ZipBuffer()
    # ZIP_STORED: PDFs are already compressed; don't burn CPU recompressing.
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_STORED) as zf:
        for path, arcname in files:
            zf.write(path, arcname)
            yield buf.drain()
    yield buf.drain()  # central directory


@router.get("/systems/{system_id}/download")
async def download_system(
    system_id: str,
    db: AsyncSession = Depends(get_db),
    _: User = Depends(get_current_user),
):
    system = await db.get(GameSystem, system_id)
    if not system:
        raise HTTPException(404, "System not found")

    books = (await db.execute(
        select(Book).where(Book.game_system_id == system_id).order_by(Book.category, Book.title)
    )).scalars().all()

    files: list[tuple[Path, str]] = []
    seen: set[str] = set()
    for b in books:
        path = Path(settings.library_path) / b.filepath
        if not path.exists():
            continue
        ext = Path(b.filename).suffix or ".pdf"
        folder = _safe_name(b.category or "uncategorized")
        arcname = f"{folder}/{_safe_name(b.title or Path(b.filename).stem)}{ext}"
        n = 2
        while arcname in seen:
            arcname = f"{folder}/{_safe_name(b.title)} ({n}){ext}"
            n += 1
        seen.add(arcname)
        files.append((path, arcname))

    if not files:
        raise HTTPException(404, "No files on disk for this system")

    zip_name = f"{_safe_name(system.name)}.zip"
    return StreamingResponse(
        _zip_stream(files),
        media_type="application/zip",
        headers={"Content-Disposition": f'attachment; filename="{zip_name}"'},
    )


@router.get("/categories")
async def list_categories(db: AsyncSession = Depends(get_db), _: User = Depends(get_current_user)):
    result = await db.execute(
        select(Book.category).distinct().where(Book.category.isnot(None)).order_by(Book.category)
    )
    return [r[0] for r in result]


@router.get("/tags")
async def list_book_tags(db: AsyncSession = Depends(get_db), _: User = Depends(get_current_user)):
    rows = (await db.execute(
        select(func.jsonb_array_elements_text(cast(Book.tags, JSONB)))
        # Guard against rows where `tags` is a JSON scalar (e.g. null) rather
        # than an array — jsonb_array_elements_text errors on those.
        .where(func.json_typeof(Book.tags) == "array")
        .distinct()
    )).all()
    return sorted({r[0] for r in rows}, key=str.lower)


_TAGGABLE = (Book, Map, Token)


def _dedup(tags: list[str]) -> list[str]:
    seen, out = set(), []
    for t in tags:
        t = (t or "").strip()
        if t and t.lower() not in seen:
            seen.add(t.lower())
            out.append(t)
    return out


@router.get("/tags/usage", dependencies=[Depends(require_admin)])
async def tag_usage(db: AsyncSession = Depends(get_db)):
    """Every tag in the library with per-content-type counts — for the
    tags-management screen."""
    counts: dict[str, dict[str, int]] = {}
    labels = {Book: "books", Map: "maps", Token: "tokens"}
    for model, label in labels.items():
        for row in (await db.execute(select(model.tags))).scalars().all():
            for t in (row or []):
                counts.setdefault(t, {"books": 0, "maps": 0, "tokens": 0})[label] += 1
    return sorted(
        (
            {"tag": tag, **c, "total": sum(c.values())}
            for tag, c in counts.items()
        ),
        key=lambda r: r["tag"].lower(),
    )


class TagRename(BaseModel):
    from_tag: str
    to_tag: str


@router.post("/tags/rename", dependencies=[Depends(require_admin)])
async def rename_tag(body: TagRename, db: AsyncSession = Depends(get_db)):
    frm, to = body.from_tag.strip(), body.to_tag.strip()
    if not frm or not to:
        raise HTTPException(422, "Both tags are required")
    changed = 0
    for model in _TAGGABLE:
        rows = (await db.execute(select(model))).scalars().all()
        for obj in rows:
            tags = obj.tags or []
            if frm not in tags:
                continue
            obj.tags = _dedup([to if t == frm else t for t in tags])
            changed += 1
    await db.commit()
    return {"ok": True, "renamed": changed}


class TagDelete(BaseModel):
    tag: str


@router.post("/tags/delete", dependencies=[Depends(require_admin)])
async def delete_tag(body: TagDelete, db: AsyncSession = Depends(get_db)):
    tag = body.tag.strip()
    if not tag:
        raise HTTPException(422, "Tag is required")
    changed = 0
    for model in _TAGGABLE:
        rows = (await db.execute(select(model))).scalars().all()
        for obj in rows:
            tags = obj.tags or []
            if tag not in tags:
                continue
            obj.tags = [t for t in tags if t != tag]
            changed += 1
    await db.commit()
    return {"ok": True, "removed": changed}


class TagsUpdate(BaseModel):
    tags: list[str]


@router.patch("/books/{book_id}/tags")
async def update_book_tags(
    book_id: str,
    body: TagsUpdate,
    db: AsyncSession = Depends(get_db),
    _: User = Depends(get_current_user),
):
    book = await db.get(Book, book_id)
    if not book:
        raise HTTPException(404, "Book not found")
    # De-dup + drop blanks client-side typos might introduce, keep input order.
    seen = set()
    clean = []
    for t in body.tags:
        t = t.strip()
        if t and t.lower() not in seen:
            seen.add(t.lower())
            clean.append(t)
    book.tags = clean
    await db.commit()
    return {"tags": clean}


@router.get("/books")
async def list_books(
    q: Optional[str] = Query(None),
    system: Optional[str] = Query(None),
    category: Optional[str] = Query(None),
    tag: Optional[str] = Query(None),
    favorites_only: bool = Query(False),
    page: int = Query(1, ge=1),
    page_size: int = Query(40, ge=1, le=500),
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    stmt = select(Book)

    if not user.allow_explicit:
        stmt = stmt.where(Book.is_explicit == False)
    if favorites_only:
        stmt = stmt.where(Book.id.in_(
            select(Favorite.item_id).where(Favorite.user_id == user.id, Favorite.item_type == "book")
        ))
    if tag:
        stmt = stmt.where(cast(Book.tags, JSONB).contains([tag]))
    if q:
        query = func.plainto_tsquery("english", q)
        # Match on title/description/publisher OR anywhere in the book's own
        # extracted page text (book_pages) — real full-document search, not
        # just metadata, now that Sanctum indexes PDFs itself.
        page_match = (
            select(BookPage.book_id)
            .where(BookPage.book_id == Book.id, BookPage.search_vector.op("@@")(query))
            .exists()
        )
        stmt = stmt.where(Book.search_vector.op("@@")(query) | page_match)
    if system:
        stmt = stmt.where(Book.game_system_id == system)
    if category:
        stmt = stmt.where(Book.category == category)

    count_stmt = select(func.count()).select_from(stmt.subquery())
    total = (await db.execute(count_stmt)).scalar_one()

    stmt = stmt.order_by(Book.title).offset((page - 1) * page_size).limit(page_size)
    books = (await db.execute(stmt)).scalars().all()

    book_ids = [b.id for b in books]
    bm_result = await db.execute(
        select(Bookmark.book_id).where(
            Bookmark.user_id == user.id,
            Bookmark.book_id.in_(book_ids),
        )
    )
    bookmarked = {row[0] for row in bm_result}
    favorited = await _favorited_ids(db, user, "book", book_ids)

    return {
        "total": total,
        "page": page,
        "page_size": page_size,
        "books": [_book_out(b, b.id in bookmarked, b.id in favorited) for b in books],
    }


@router.get("/books/{book_id}")
async def get_book(
    book_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    book = await db.get(Book, book_id)
    if not book:
        raise HTTPException(404, "Book not found")

    bm = (await db.execute(
        select(Bookmark).where(Bookmark.user_id == user.id, Bookmark.book_id == book_id)
    )).scalar_one_or_none()
    fav = (await db.execute(
        select(Favorite).where(Favorite.user_id == user.id, Favorite.item_type == "book", Favorite.item_id == book_id)
    )).scalar_one_or_none()

    return _book_out(book, bm is not None, fav is not None)


class BookMetadataUpdate(BaseModel):
    title: Optional[str] = None
    category: Optional[str] = None
    description: Optional[str] = None
    authors: Optional[list[str]] = None
    publisher: Optional[str] = None
    publisher_url: Optional[str] = None
    isbn: Optional[str] = None
    license: Optional[str] = None
    year: Optional[int] = None
    is_explicit: Optional[bool] = None


@router.patch("/books/{book_id}", dependencies=[Depends(require_admin)])
async def update_book_metadata(
    book_id: str,
    body: BookMetadataUpdate,
    db: AsyncSession = Depends(get_db),
):
    book = await db.get(Book, book_id)
    if not book:
        raise HTTPException(404, "Book not found")
    # exclude_unset: same reasoning as the wiki PATCH fix — description/year/
    # etc. need to be clearable back to null, which exclude_none would drop.
    updates = body.model_dump(exclude_unset=True)
    if "title" in updates and not (updates["title"] or "").strip():
        raise HTTPException(422, "Title cannot be empty")
    for field, value in updates.items():
        setattr(book, field, value)
    await db.commit()
    return {"ok": True}


@router.get("/books/{book_id}/file")
async def get_book_file(
    book_id: str,
    db: AsyncSession = Depends(get_db),
    _: User = Depends(get_current_user),
):
    book = await db.get(Book, book_id)
    if not book:
        raise HTTPException(404, "Book not found")

    path = Path(settings.library_path) / book.filepath
    if not path.exists():
        raise HTTPException(404, "File not found on disk")

    media_type = book.mime_type or mimetypes.guess_type(str(path))[0] or "application/octet-stream"
    # Serve inline so the browser opens it in the PDF viewer rather than downloading,
    # but give it the book title as filename so "Save as" doesn't produce "file".
    ext = Path(book.filename).suffix or ".pdf"
    nice_name = f"{book.title}{ext}" if book.title else book.filename
    nice_name = re.sub(r'[\\/:*?"<>|]', "-", nice_name)
    return FileResponse(
        path, media_type=media_type,
        filename=nice_name, content_disposition_type="inline",
    )


@router.get("/books/{book_id}/thumbnail")
async def get_book_thumbnail(
    book_id: str,
    db: AsyncSession = Depends(get_db),
    _: User = Depends(get_current_user),
):
    book = await db.get(Book, book_id)
    if not book:
        raise HTTPException(404)

    # Prefer a pre-existing (pre-migration) thumbnail; fall back
    # to a freshly-generated one only for books that never had a
    # thumbnail for (e.g. added directly to the library after the migration).
    if book.has_thumbnail:
        slug = _thumb_slug(book.filename)
        thumbs_dir = Path(settings.thumbnails_path) / "books"
        matches = sorted(thumbs_dir.glob(f"{slug}_*.webp"))
        if matches:
            return FileResponse(matches[0], media_type="image/webp")

    own_path = indexing.thumbnail_path(book)
    if own_path.exists():
        return FileResponse(own_path, media_type="image/webp")

    raise HTTPException(404)


@router.get("/books/{book_id}/toc")
async def get_book_toc(
    book_id: str,
    db: AsyncSession = Depends(get_db),
    _: User = Depends(get_current_user),
):
    """A PDF's own embedded outline/bookmarks, nested by level.

    Own implementation
    ``(level, title, page)`` tuples and rebuilds the tree structure.
    """
    book = await db.get(Book, book_id)
    if not book or book.mime_type != "application/pdf":
        raise HTTPException(404)

    path = Path(settings.library_path) / book.filepath
    if not path.exists():
        raise HTTPException(404, "File not found on disk")

    def _read_toc() -> list[dict]:
        doc = fitz.open(str(path))
        try:
            raw = doc.get_toc(simple=True)
        finally:
            doc.close()

        def build_tree(items, min_level):
            result = []
            i = 0
            while i < len(items):
                level, title, page = items[i]
                if level < min_level:
                    break
                if level == min_level:
                    j = i + 1
                    while j < len(items) and items[j][0] > min_level:
                        j += 1
                    result.append({
                        "title": title,
                        "page": page,
                        "level": level,
                        "children": build_tree(items[i + 1 : j], min_level + 1),
                    })
                    i = j
                else:
                    i += 1
            return result

        min_lvl = min((r[0] for r in raw), default=1)
        return build_tree(raw, min_lvl)

    return {"toc": await asyncio.to_thread(_read_toc)}


def _render_book_page(filepath: Path, page_num: int, width: int) -> bytes:
    """Thin wrapper over pdf_render.render_pdf_page — maps its ValueError for an
    out-of-range page onto the HTTP 400 the reader endpoint expects."""
    try:
        return render_pdf_page(filepath, page_num, width)
    except ValueError as e:
        raise HTTPException(400, str(e))


@router.get("/books/{book_id}/page/{page_num}")
async def get_book_page(
    book_id: str,
    page_num: int,
    width: int = Query(1200, le=3000),
    db: AsyncSession = Depends(get_db),
    _: User = Depends(get_current_user),
):
    """A single rendered page image for the Page/Spread reader views."""
    book = await db.get(Book, book_id)
    if not book or book.mime_type != "application/pdf":
        raise HTTPException(404)

    path = Path(settings.library_path) / book.filepath
    if not path.exists():
        raise HTTPException(404, "File not found on disk")

    img_bytes = await asyncio.to_thread(_render_book_page, path, page_num, width)
    return StreamingResponse(
        io.BytesIO(img_bytes),
        media_type="image/webp",
        headers={"Cache-Control": "public, max-age=86400"},
    )


def _get_book_page_words(filepath: Path, page_num: int) -> dict:
    """Thin wrapper over pdf_render.get_pdf_page_words — same ValueError→400
    mapping as _render_book_page."""
    try:
        return get_pdf_page_words(filepath, page_num)
    except ValueError as e:
        raise HTTPException(400, str(e))


@router.get("/books/{book_id}/page/{page_num}/words")
async def get_book_page_words(
    book_id: str,
    page_num: int,
    db: AsyncSession = Depends(get_db),
    _: User = Depends(get_current_user),
):
    """Word bounding boxes for one page — powers the reader's text-selection
    overlay. An empty `words` list means no embedded text layer (a scanned
    page with no OCR written back into the PDF), not an error."""
    book = await db.get(Book, book_id)
    if not book or book.mime_type != "application/pdf":
        raise HTTPException(404)

    path = Path(settings.library_path) / book.filepath
    if not path.exists():
        raise HTTPException(404, "File not found on disk")

    return await asyncio.to_thread(_get_book_page_words, path, page_num)


@router.get("/books/{book_id}/search")
async def search_book_pages(
    book_id: str,
    q: str = Query(..., min_length=1),
    db: AsyncSession = Depends(get_db),
    _: User = Depends(get_current_user),
):
    """Full-text search within one book's own extracted page content.

    Returns matching pages with a highlighted snippet, ordered by page number
    — lets the reader UI jump straight to a hit instead of skimming the PDF.
    """
    if not await db.get(Book, book_id):
        raise HTTPException(404, "Book not found")

    query = func.plainto_tsquery("english", q)
    rows = (await db.execute(
        select(
            BookPage.page_number,
            func.ts_headline(
                "english", BookPage.content, query,
                "MaxFragments=1, MaxWords=35, MinWords=15",
            ).label("snippet"),
        )
        .where(BookPage.book_id == book_id, BookPage.search_vector.op("@@")(query))
        .order_by(BookPage.page_number)
        .limit(200)
    )).all()
    return [{"page_number": r.page_number, "snippet": r.snippet} for r in rows]


# ── Indexing (admin) ──────────────────────────────────────────────────────────

@router.post("/books/{book_id}/reindex", dependencies=[Depends(require_admin)])
async def reindex_book(book_id: str, db: AsyncSession = Depends(get_db)):
    """Re-extract text, thumbnail, and OCR state for one book from disk."""
    book = await db.get(Book, book_id)
    if not book:
        raise HTTPException(404, "Book not found")
    await indexing.reindex_single_book(book, db)
    return _book_out(book)


@router.post("/books", status_code=201, dependencies=[Depends(require_admin)])
async def upload_book(
    file: UploadFile = File(...),
    system: str = Form(...),
    db: AsyncSession = Depends(get_db),
):
    """Admin: drop a PDF into LIBRARY_PATH/books/<system>/ and register it.

    `system` is the game-system folder name (existing or new). The file then
    goes through the same scan + index pipeline as one placed on disk manually.
    """
    if Path(file.filename or "").suffix.lower() != ".pdf":
        raise HTTPException(400, "Only PDF files are supported")

    system_folder = library_scan.slugify(system) or "misc"
    safe_name = re.sub(r'[\\/:*?"<>|]', "-", Path(file.filename).name)
    dest_dir = Path(settings.library_path) / "books" / system_folder
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / safe_name
    if dest.exists():
        raise HTTPException(409, "A book with that filename already exists in this system")
    dest.write_bytes(await file.read())

    stats = await library_scan.scan_new_books(db, metadata_mode="new")
    asyncio.create_task(indexing.scan_and_index())
    return {"ok": True, "system": system_folder, "filename": safe_name, "scan": stats}


@router.post("/scan", dependencies=[Depends(require_admin)])
async def scan_library(
    mode: str = Query("new", pattern="^(new|missing|replace)$"),
    db: AsyncSession = Depends(get_db),
):
    """Walk the library folder for new/changed books, then reprocess them.

    Three modes, the manual-scan options:
      - "new" (default, "Find New Files"): register any PDF on disk with no
        Book row yet, flag/unflag missing files. Existing rows' metadata is
        left untouched.
      - "missing" ("Update missing metadata"): also fill empty metadata
        fields on existing books from a sidecar .opf file, if one exists.
      - "replace" ("Replace all metadata"): also overwrite metadata fields
        wherever a sidecar .opf provides a value.
    Newly registered books are left un-indexed/un-thumbnailed; this kicks off
    an immediate background pass (rather than waiting up to 30 min for the
    next scheduled tick) so they show up searchable right away.
    """
    stats = await library_scan.scan_new_books(db, metadata_mode=mode)
    asyncio.create_task(indexing.scan_and_index())
    return stats


# ── Bookmarks (per-book, multiple allowed) ────────────────────────────────────

@router.get("/books/{book_id}/bookmarks")
async def list_book_bookmarks(
    book_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    bms = (await db.execute(
        select(Bookmark)
        .where(Bookmark.user_id == user.id, Bookmark.book_id == book_id)
        .order_by(Bookmark.page_number, Bookmark.created_at)
    )).scalars().all()
    return [_bookmark_out(bm) for bm in bms]


@router.post("/books/{book_id}/bookmarks", status_code=201)
async def add_bookmark(
    book_id: str,
    body: BookmarkCreate,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    if not await db.get(Book, book_id):
        raise HTTPException(404, "Book not found")
    bm = Bookmark(
        user_id=user.id,
        book_id=book_id,
        page_number=body.page_number,
        label=body.label,
        notes=body.notes,
        selected_text=body.selected_text,
    )
    db.add(bm)
    await db.commit()
    await db.refresh(bm)
    return _bookmark_out(bm)


@router.patch("/bookmarks/{bookmark_id}")
async def update_bookmark(
    bookmark_id: int,
    body: BookmarkCreate,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    bm = await db.get(Bookmark, bookmark_id)
    if not bm or bm.user_id != user.id:
        raise HTTPException(404)
    for field, value in body.model_dump(exclude_none=True).items():
        setattr(bm, field, value)
    await db.commit()
    return _bookmark_out(bm)


@router.delete("/bookmarks/{bookmark_id}", status_code=204)
async def remove_bookmark(
    bookmark_id: int,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    bm = await db.get(Bookmark, bookmark_id)
    if bm and bm.user_id == user.id:
        await db.delete(bm)
        await db.commit()


@router.get("/bookmarks")
async def list_all_bookmarks(
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    rows = (await db.execute(
        select(Book, Bookmark)
        .join(Bookmark, Bookmark.book_id == Book.id)
        .where(Bookmark.user_id == user.id)
        .order_by(Book.title, Bookmark.page_number)
    )).all()
    result = []
    for book, bm in rows:
        entry = _book_out(book, True)
        entry["bookmark"] = _bookmark_out(bm)
        result.append(entry)
    return result
