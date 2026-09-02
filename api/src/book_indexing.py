"""Async orchestration for Sanctum's own PDF indexing pipeline.

Own implementation.py + _subprocess.py's
``ocr_book``, adapted from sync SQLAlchemy Session to Sanctum's AsyncSession.
The actual CPU/process-bound work (text extraction, OCR, thumbnailing) lives
in the framework-agnostic ``indexer`` package and runs off the event loop via
``asyncio.to_thread`` (the isolated child process itself is spawned from that
thread, so a native crash still can't take down the API server).

This is what makes Sanctum's library self-sufficient instead of a read-only
dependent on externally-computed metadata: every book gets its own
page-level full-text index (``book_pages``) and its own generated thumbnail,
computed by this pipeline, not read from an external source.
"""
import asyncio
import hashlib
import logging
import re
from pathlib import Path
from typing import Callable, Optional

from fastapi import FastAPI
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession

from . import indexer
from .config import settings
from .database import SessionLocal
from .models import Book

logger = logging.getLogger("sanctum.indexing")

_SCAN_INTERVAL = 1800  # seconds between background scan passes


def slugify(value: str) -> str:
    """Slug convention for thumbnail filenames."""
    slug = (value or "").lower().strip()
    slug = re.sub(r"[^\w\s-]", "", slug)
    slug = re.sub(r"[\s_-]+", "-", slug)
    return slug.strip("-")


def thumbnail_path(book: Book) -> Path:
    slug = slugify(book.title or book.filename)
    digest = hashlib.md5(book.filepath.encode()).hexdigest()[:8]
    return Path(settings.book_thumbnails_path) / "books" / f"{slug}_{digest}.webp"


async def _upsert_page(db: AsyncSession, book_id: str, page_number: int, content: str) -> None:
    # Postgres text columns reject NUL bytes outright (CharacterNotInRepertoireError);
    # PyMuPDF occasionally extracts one from a malformed embedded text layer,
    # which would otherwise crash the whole insert.
    content = content.replace("\x00", "")
    await db.execute(
        text(
            "INSERT INTO book_pages (book_id, page_number, content) "
            "VALUES (:bid, :pnum, :content) "
            "ON CONFLICT (book_id, page_number) DO UPDATE SET content = EXCLUDED.content"
        ),
        {"bid": book_id, "pnum": page_number, "content": content},
    )


async def generate_book_thumbnail(book: Book, db: AsyncSession) -> bool:
    filepath = str(Path(settings.library_path) / book.filepath)
    out_path = thumbnail_path(book)
    ok = await asyncio.to_thread(indexer.generate_thumbnail, filepath, str(out_path))
    if ok and not book.has_thumbnail:
        book.has_thumbnail = True
        await db.commit()
    return ok


async def index_book_text(
    book: Book,
    db: AsyncSession,
    should_stop: Optional[Callable[[], bool]] = None,
) -> bool:
    """Extract and index text from a PDF for full-text search.

    Text extraction runs in an isolated worker process. Before extraction the
    book is marked ``index_failed`` and committed, so that even if a native
    crash escaped the isolation and took down the whole server, the book would
    already be flagged and skipped on the next scan instead of re-crashing in
    an endless loop. The flag is cleared on success.
    """
    if book.indexed or book.index_failed or book.mime_type != "application/pdf":
        return False

    filepath = str(Path(settings.library_path) / book.filepath)

    book.index_failed = True
    await db.commit()

    logger.debug(f"Indexing: extracting text from '{book.filepath}'")
    try:
        # text_only: never OCR inline. Image-only books come back with no pages
        # and are queued for the deferred-OCR worker below, so a large scanned
        # book can't stall the scan for hours or hit the whole-book timeout.
        pages, used_ocr = await asyncio.to_thread(
            indexer.extract_text_isolated,
            filepath,
            should_stop=should_stop,
            text_only=True,
        )
    except indexer.PdfExtractionCrashError as e:
        logger.error(f"Text extraction crashed for '{book.filename}': {e} — marking index_failed")
        book.index_error = f"extraction crashed: {e}"[:500]
        book.index_failed = True
        await db.commit()
        return False
    except TimeoutError:
        # Cancelled via should_stop — clear the attempt marker so the file is
        # resumed on the next scan rather than left permanently failed.
        book.index_failed = False
        await db.commit()
        return False

    if not pages:
        if indexer.ocr.ocr_available():
            logger.info(
                f"'{book.title or book.filename}' is a scanned book with no text — "
                f"queued to read text from later."
            )
            book.ocr_pending = True
            book.ocr_pages_done = 0
            book.indexed = False
            book.index_failed = False
            book.index_error = ""
            await db.commit()
            return False
        logger.info(
            f"'{book.title or book.filename}' is a scanned book with no text — "
            f"it won't be searchable (text recognition is off)."
        )
        book.index_error = "image-only"
        book.indexed = True
        book.index_failed = False
        await db.commit()
        return True

    logger.debug(f"Indexing: inserting {len(pages)} pages for '{book.filename}'")
    for page_data in pages:
        await _upsert_page(db, book.id, page_data["page"], page_data["content"])

    book.indexed = True
    book.index_failed = False
    book.index_error = "ocr" if used_ocr else ""
    await db.commit()
    logger.info(f"'{book.title or book.filename}' is now searchable ({len(pages)} page(s)).")
    return True


async def ocr_book(
    book: Book,
    db: AsyncSession,
    should_stop: Optional[Callable[[], bool]] = None,
) -> str:
    """OCR one queued book page-by-page, checkpointing progress as it goes.

    Resumes from ``book.ocr_pages_done``: pages at or below that index were
    already OCR'd and committed in a prior run, so a restart or crash never
    loses work and never re-does a page. Returns ``"done"``, ``"stopped"``
    (cancelled — resumable), or ``"error"`` (page count unreadable).
    """
    filepath = str(Path(settings.library_path) / book.filepath)
    try:
        page_count = await asyncio.to_thread(indexer.book_page_count, filepath)
    except Exception as e:
        logger.error(f"OCR: cannot open '{book.filename}' to count pages: {e}")
        book.ocr_pending = False
        book.index_failed = True
        book.index_error = f"ocr open failed: {e}"[:500]
        await db.commit()
        return "error"

    start = book.ocr_pages_done or 0
    dpi = book.ocr_dpi
    logger.info(
        f"Reading text from '{book.title or book.filename}' — {page_count} page(s)"
        f"{f' (from page {start + 1})' if start else ''}…"
    )
    for i in range(start, page_count):
        if should_stop and should_stop():
            logger.debug(f"OCR: stop requested during '{book.filename}' at page {i + 1}")
            return "stopped"

        text_out = await asyncio.to_thread(
            indexer.ocr_page_isolated, filepath, i, should_stop=should_stop, dpi=dpi
        )

        if should_stop and should_stop():
            logger.debug(f"OCR: stop requested during '{book.filename}' at page {i + 1}")
            return "stopped"

        if text_out:
            await _upsert_page(db, book.id, i + 1, text_out)

        # Advance the checkpoint whether the page yielded text, was legitimately
        # blank, or was abandoned (crash/timeout, already logged there). A single
        # pathological page can't stall or loop the book forever.
        book.ocr_pages_done = i + 1
        await db.commit()

    book.ocr_pending = False
    book.indexed = True
    book.index_failed = False
    book.index_error = "ocr"
    await db.commit()
    logger.info(f"Finished reading '{book.title or book.filename}' — it's now searchable.")
    return "done"


async def reindex_single_book(book: Book, db: AsyncSession) -> None:
    """Re-read one book from disk and rebuild its search index + thumbnail in place."""
    if book.mime_type != "application/pdf":
        return

    filepath = str(Path(settings.library_path) / book.filepath)
    try:
        book.page_count = await asyncio.to_thread(indexer.book_page_count, filepath)
    except Exception as e:
        logger.warning(f"Re-index: could not read page count for '{book.filename}': {e}")

    await generate_book_thumbnail(book, db)

    await db.execute(text("DELETE FROM book_pages WHERE book_id = :bid"), {"bid": book.id})
    book.indexed = False
    book.index_failed = False
    book.index_error = ""
    book.ocr_pending = False
    book.ocr_pages_done = 0
    await db.commit()

    await index_book_text(book, db)


async def scan_and_index(should_stop: Optional[Callable[[], bool]] = None) -> None:
    """Sweep the library for books needing (re-)indexing, a thumbnail, or OCR."""
    async with SessionLocal() as db:
        result = await db.execute(
            select(Book).where(
                Book.mime_type == "application/pdf",
                Book.indexed == False,  # noqa: E712
                Book.index_failed == False,  # noqa: E712
                Book.ocr_pending == False,  # noqa: E712
            )
        )
        for book in result.scalars().all():
            if should_stop and should_stop():
                return
            try:
                await index_book_text(book, db, should_stop=should_stop)
                if not (await asyncio.to_thread(thumbnail_path(book).exists)):
                    await generate_book_thumbnail(book, db)
            except Exception:
                # A single malformed file (or an unexpected DB error, e.g. an
                # encoding issue in extracted text) must not poison this
                # session's transaction for every other book in the sweep, or
                # stall the whole 30-min cycle on one bad PDF.
                logger.exception(f"Unexpected error indexing '{book.filename}' — marking failed")
                await db.rollback()
                book.index_failed = True
                book.index_error = "unexpected indexing error"
                await db.commit()

        result = await db.execute(select(Book).where(Book.ocr_pending == True))  # noqa: E712
        for book in result.scalars().all():
            if should_stop and should_stop():
                return
            try:
                await ocr_book(book, db, should_stop=should_stop)
            except Exception:
                logger.exception(f"Unexpected error OCRing '{book.filename}' — marking failed")
                await db.rollback()
                book.ocr_pending = False
                book.index_failed = True
                book.index_error = "unexpected OCR error"
                await db.commit()


async def _scan_loop(app: FastAPI) -> None:
    stop_event: asyncio.Event = app.state.book_scan_stop_event
    should_stop = stop_event.is_set
    while not stop_event.is_set():
        try:
            await scan_and_index(should_stop=should_stop)
        except Exception:
            logger.exception("Background book scan failed")
        try:
            await asyncio.wait_for(stop_event.wait(), timeout=_SCAN_INTERVAL)
        except asyncio.TimeoutError:
            pass


def start_background_scan(app: FastAPI) -> None:
    app.state.book_scan_stop_event = asyncio.Event()
    app.state.book_scan_task = asyncio.create_task(_scan_loop(app))


def stop_background_scan(app: FastAPI) -> None:
    stop_event: Optional[asyncio.Event] = getattr(app.state, "book_scan_stop_event", None)
    if stop_event is not None:
        stop_event.set()
    task = getattr(app.state, "book_scan_task", None)
    if task is not None:
        task.cancel()
