"""Optional OCR support for image-only PDFs.

Own implementation.py. Image-only PDFs (scanned pages with no
embedded text layer) yield no text from PyMuPDF's ``get_text()`` and would
otherwise be excluded from full-text search. When Tesseract is available, the
indexer renders each such page to an image and runs it through OCR here so the
recognised text can be added to the FTS index.

Everything is best-effort and degrades gracefully: if the tesseract binary is
absent, ``ocr_available()`` returns False and callers fall back to marking the
book ``image-only``. OCR is CPU-heavy and can hang on pathological input, so
``ocr_image`` runs Tesseract in a daemon thread with a timeout.

Config is read directly from the environment (``OCR_ENABLED``, ``OCR_LANGUAGES``,
``OCR_DPI``) rather than Sanctum's pydantic Settings, keeping this whole
package importable standalone inside the isolated subprocess.
"""

import logging
import os
import threading
from typing import Callable, Optional

import fitz
from PIL import Image

logger = logging.getLogger("sanctum.indexer")

# Per-page OCR budget. Scanned pages are slow; anything beyond this is treated
# as a hang and abandoned so a single bad page can't stall the whole scan.
_OCR_TIMEOUT = 120  # seconds

# Cached result of the tesseract-binary probe (None = not yet probed).
_available: bool | None = None


def ocr_enabled() -> bool:
    return os.environ.get("OCR_ENABLED", "true").lower() == "true"


def ocr_languages() -> str:
    return os.environ.get("OCR_LANGUAGES", "eng").strip() or "eng"


def _probe_tesseract() -> bool:
    """Return True if pytesseract is importable and the tesseract binary runs."""
    try:
        import pytesseract  # local import keeps startup light if tesseract is absent

        pytesseract.get_tesseract_version()
        return True
    except Exception as exc:  # ImportError, TesseractNotFoundError, etc.
        logger.debug(f"Tesseract not available: {exc}")
        return False


def ocr_available() -> bool:
    """Whether OCR can run: enabled in env AND tesseract is usable.

    The tesseract probe is cached after the first call; ``OCR_ENABLED`` is
    read live so it can be toggled without restarting the probe cache.
    """
    global _available
    if not ocr_enabled():
        return False
    if _available is None:
        _available = _probe_tesseract()
        if _available:
            logger.info(f"Text recognition for scanned books is on (languages: {ocr_languages()}).")
        else:
            logger.info("Text recognition for scanned books is off — Tesseract isn't installed.")
    return _available


def reset_availability_cache() -> None:
    """Clear the cached tesseract probe."""
    global _available
    _available = None


def effective_languages() -> str:
    return ocr_languages()


def _ocr_task(image: Image.Image, result: list, exc: list) -> None:
    """Worker executed in a daemon thread by ocr_image."""
    try:
        import pytesseract

        result[0] = pytesseract.image_to_string(image, lang=ocr_languages())
    except Exception as e:
        exc[0] = e


def ocr_image(image: Image.Image, should_stop: Optional[Callable[[], bool]] = None) -> str:
    """Run OCR on a PIL image, returning the recognised text (stripped).

    Runs in a daemon thread with a timeout so a wedged OCR call can't hang the
    scan. Returns "" on timeout, error, or empty result — never raises.
    """
    result = [None]
    exc = [None]
    t = threading.Thread(target=_ocr_task, args=(image, result, exc), daemon=True)
    t.start()
    poll_interval = 0.5
    elapsed = 0.0
    while t.is_alive() and elapsed < _OCR_TIMEOUT:
        t.join(poll_interval)
        elapsed += poll_interval
        if should_stop and should_stop():
            logger.debug("OCR aborted by stop request")
            return ""
    if t.is_alive():
        logger.warning(f"Gave up reading a page after {_OCR_TIMEOUT}s — skipping it.")
        return ""
    if exc[0] is not None:
        logger.warning(f"Couldn't read text from a page: {exc[0]}")
        return ""
    return (result[0] or "").strip()


def ocr_pixmap(pixmap: "fitz.Pixmap", should_stop: Optional[Callable[[], bool]] = None) -> str:
    """Run OCR on a PyMuPDF pixmap by converting it to a PIL image first."""
    try:
        image = Image.frombytes("RGB", [pixmap.width, pixmap.height], pixmap.samples)
    except Exception as exc:
        logger.error(f"Could not convert page pixmap for OCR: {exc}")
        return ""
    return ocr_image(image, should_stop=should_stop)
