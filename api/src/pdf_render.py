"""Shared PDF page rendering — used by the book reader and the map viewer.

``fitz``/Pillow calls are blocking; callers wrap these in
``asyncio.to_thread``. Rendered pages are disk-cached by file+page+width
(Sanctum has no in-memory cache tier). Word bounding boxes (for the reader's
text-selection overlay) are cached separately by file+page only, since those
coordinates are resolution-independent.
"""
import hashlib
import io
import json
from pathlib import Path
import fitz  # PyMuPDF
from PIL import Image
from .config import settings


def pdf_page_count(filepath: Path) -> int:
    doc = fitz.open(str(filepath))
    try:
        return len(doc)
    finally:
        doc.close()


def render_pdf_page(filepath: Path, page_num: int, width: int) -> bytes:
    """Render one PDF page (1-indexed) to WebP bytes, disk-cached."""
    file_hash = hashlib.sha1(str(filepath).encode()).hexdigest()[:16]
    cache_path = Path(settings.page_cache_path) / f"{file_hash}_{page_num}_{width}.webp"
    if cache_path.exists():
        return cache_path.read_bytes()

    doc = fitz.open(str(filepath))
    try:
        if page_num < 1 or page_num > len(doc):
            raise ValueError(f"page {page_num} out of range 1..{len(doc)}")
        page = doc[page_num - 1]
        zoom = width / page.rect.width
        pix = page.get_pixmap(matrix=fitz.Matrix(zoom, zoom), alpha=False)
        img = Image.frombytes("RGB", (pix.width, pix.height), pix.samples)
    finally:
        doc.close()

    buf = io.BytesIO()
    img.save(buf, format="webp", quality=85, method=0)
    img_bytes = buf.getvalue()

    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache_path.write_bytes(img_bytes)
    return img_bytes


def get_pdf_page_words(filepath: Path, page_num: int) -> dict:
    """Word-level bounding boxes for one PDF page (1-indexed), disk-cached.

    Coordinates are in PDF points (page.rect space), not pixels — the cache
    key omits width/zoom, unlike render_pdf_page's, since these are
    resolution-independent. Returns an empty "words" list for pages with no
    embedded text layer (e.g. a scanned page whose text only exists via OCR
    in book_pages, never written back into the PDF itself) — callers must
    treat that as "no selectable text", not an error.
    """
    file_hash = hashlib.sha1(str(filepath).encode()).hexdigest()[:16]
    cache_path = Path(settings.page_cache_path) / f"{file_hash}_{page_num}_words.json"
    if cache_path.exists():
        return json.loads(cache_path.read_text())

    doc = fitz.open(str(filepath))
    try:
        if page_num < 1 or page_num > len(doc):
            raise ValueError(f"page {page_num} out of range 1..{len(doc)}")
        page = doc[page_num - 1]
        # sort=True: PyMuPDF's own top-to-bottom/left-to-right ordering pass —
        # more reliable than trusting raw block/line/word numbers for
        # contiguous-run text selection. Known limitation: strict multi-column
        # layouts (rulebook sidebars) can still interleave; accepted per the
        # contiguous-run selection model, not solved here.
        raw = page.get_text("words", sort=True)
        result = {
            "page_width": page.rect.width,
            "page_height": page.rect.height,
            "words": [{"text": w[4], "x0": w[0], "y0": w[1], "x1": w[2], "y1": w[3]} for w in raw],
        }
    finally:
        doc.close()

    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(json.dumps(result))
    return result
