"""Cover thumbnail generation for library books.

Own implementation.py — Sanctum's library is PDFs
only (no comic-archive support), so this only covers the PDF-first-page and
generic-image cases.
"""
import logging
import os
import threading
from pathlib import Path
from typing import Callable, Optional

import fitz  # PyMuPDF
from PIL import Image

from .constants import _THUMBNAIL_TIMEOUT

logger = logging.getLogger("sanctum.indexer")

IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".tiff"}


def _generate_thumbnail_task(
    filepath: str, output_path: str, size: tuple, result: list, exc: list
) -> None:
    """Worker executed in a daemon thread by generate_thumbnail."""
    try:
        ext = Path(filepath).suffix.lower()
        if ext == ".pdf":
            doc = fitz.open(filepath)
            if len(doc) == 0:
                result[0] = False
                return
            page = doc[0]
            mat = fitz.Matrix(2, 2)
            pix = page.get_pixmap(matrix=mat, alpha=False)
            img = Image.frombytes("RGB", [pix.width, pix.height], pix.samples)
            doc.close()
        elif ext in IMAGE_EXTS:
            img = Image.open(filepath)
            if img.mode != "RGB":
                img = img.convert("RGB")
        else:
            result[0] = False
            return

        img.thumbnail(size, Image.LANCZOS)
        os.makedirs(os.path.dirname(output_path), exist_ok=True)
        img.save(output_path, "WEBP", quality=80)
        result[0] = True
    except Exception as e:
        exc[0] = e


def generate_thumbnail(
    filepath: str,
    output_path: str,
    size: tuple = (300, 400),
    should_stop: Optional[Callable[[], bool]] = None,
) -> bool:
    """Generate a thumbnail from the first page of a PDF or from an image.

    Runs in a daemon thread with a timeout so a corrupt or pathologically
    large file cannot hang the scan indefinitely.
    """
    result = [None]
    exc = [None]
    t = threading.Thread(
        target=_generate_thumbnail_task,
        args=(filepath, output_path, size, result, exc),
        daemon=True,
    )
    t.start()
    poll_interval = 0.5
    elapsed = 0.0
    while t.is_alive() and elapsed < _THUMBNAIL_TIMEOUT:
        t.join(poll_interval)
        elapsed += poll_interval
        if should_stop and should_stop():
            logger.warning(f"Thumbnail generation aborted by stop request for {filepath}")
            return False
    if t.is_alive():
        logger.error(f"Thumbnail generation timed out after {_THUMBNAIL_TIMEOUT}s for {filepath}")
        return False
    if exc[0] is not None:
        logger.error(f"Thumbnail generation failed for {filepath}: {exc[0]}")
        return False
    return bool(result[0])
