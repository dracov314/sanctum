"""Isolated PDF text extraction and per-page OCR, run in spawned child processes.

Own implementation.py. A native crash inside
MuPDF/Tesseract (segfault, OOM-kill) or a pathological hang can only take down
a throwaway child process here, never the API server itself — the caller
checkpoints progress and moves on.
"""
import logging
import os
import pickle
import tempfile
import threading
from typing import Any, Callable, Optional

import fitz  # PyMuPDF

from .constants import _EXTRACT_TIMEOUT, _FITZ_TIMEOUT, _MP_CONTEXT, _OCR_PAGE_TIMEOUT
from . import ocr

logger = logging.getLogger("sanctum.indexer")


class PdfExtractionCrashError(Exception):
    """The isolated extraction worker died (segfault, OOM-kill, or timeout).

    Raised by ``extract_text_isolated`` when the child process terminates
    without producing a result. The caller marks the book failed so the file
    is skipped instead of crashing the server and re-looping the scan.
    """


def _run_with_timeout(fn: Callable[[], Any], timeout: int, label: str) -> Any:
    """Run fn() in a daemon thread. Returns its result, or raises TimeoutError if it
    does not complete within `timeout` seconds. `label` is used in log/error messages."""
    result = [None]
    exc = [None]

    def _worker() -> None:
        try:
            result[0] = fn()
        except Exception as e:
            exc[0] = e

    t = threading.Thread(target=_worker, daemon=True)
    t.start()
    t.join(timeout)
    if t.is_alive():
        raise TimeoutError(f"operation timed out after {timeout}s: {label}")
    if exc[0] is not None:
        raise exc[0]
    return result[0]


def _fitz_open_with_timeout(
    filepath: str,
    timeout: int = _FITZ_TIMEOUT,
    should_stop: Optional[Callable[[], bool]] = None,
) -> "fitz.Document":
    """Open a PDF with fitz, raising TimeoutError if it hangs beyond `timeout` seconds."""
    result = [None]
    exc = [None]

    def _open() -> None:
        try:
            result[0] = fitz.open(filepath)
        except Exception as e:
            exc[0] = e

    t = threading.Thread(target=_open, daemon=True)
    t.start()
    poll_interval = 0.5
    elapsed = 0.0
    while t.is_alive() and elapsed < timeout:
        t.join(poll_interval)
        elapsed += poll_interval
        if should_stop and should_stop():
            raise TimeoutError(f"fitz.open() aborted by stop request for {filepath}")
    if t.is_alive():
        raise TimeoutError(f"fitz.open() timed out after {timeout}s for {filepath}")
    if exc[0] is not None:
        raise exc[0]
    return result[0]


def extract_text_isolated(
    filepath: str,
    should_stop: Optional[Callable[[], bool]] = None,
    text_only: bool = False,
) -> tuple[list[dict], bool]:
    """Extract text from a PDF in a separate process, isolating native crashes.

    Returns ``(pages, used_ocr)``: ``pages`` is a list of ``{page, content}``
    dicts. If the child dies without producing a result — a segfault inside
    MuPDF, an OOM-kill, or exceeding ``_EXTRACT_TIMEOUT`` — raises
    ``PdfExtractionCrashError``.

    With ``text_only=True`` the child skips OCR (fast scan phase): image-only
    pages come back empty and the caller queues the book for deferred OCR
    instead of OCRing inline (which could stall the scan for hours on a large
    scanned book).
    """
    from . import pdf_worker

    fd, result_path = tempfile.mkstemp(prefix="sanctum_extract_", suffix=".pkl")
    os.close(fd)
    proc = _MP_CONTEXT.Process(target=pdf_worker.main, args=(filepath, result_path, text_only))
    try:
        proc.start()
        poll_interval = 0.5
        elapsed = 0.0
        while proc.is_alive() and elapsed < _EXTRACT_TIMEOUT:
            proc.join(poll_interval)
            elapsed += poll_interval
            if should_stop and should_stop():
                proc.terminate()
                proc.join()
                raise TimeoutError(f"Text extraction aborted by stop request for {filepath}")

        if proc.is_alive():
            logger.error(f"Text extraction timed out after {_EXTRACT_TIMEOUT}s for {filepath}")
            proc.terminate()
            proc.join()
            raise PdfExtractionCrashError(f"extraction timed out after {_EXTRACT_TIMEOUT}s")

        # Child exited. A clean run left a result file; a crash (negative
        # exitcode = killed by signal, or nonzero without a result) did not.
        if os.path.getsize(result_path) == 0:
            code = proc.exitcode
            reason = (
                f"killed by signal {-code}"
                if code is not None and code < 0
                else f"exited with code {code}"
            )
            logger.error(f"Text extraction worker crashed ({reason}) for {filepath}")
            raise PdfExtractionCrashError(f"extraction worker {reason}")

        with open(result_path, "rb") as fh:
            return pickle.load(fh)
    finally:
        if proc.is_alive():
            proc.terminate()
            proc.join()
        try:
            os.unlink(result_path)
        except OSError as e:
            logger.debug("Failed to remove temp result file %s: %s", result_path, e)


def ocr_page_isolated(
    filepath: str,
    page_index: int,
    should_stop: Optional[Callable[[], bool]] = None,
    dpi: int | None = None,
) -> str:
    """OCR a single page in a spawned child, bounded by ``_OCR_PAGE_TIMEOUT``.

    Returns the recognised text ("" on timeout, crash, cancel, or empty result
    — never raises). Isolation means a native OCR/MuPDF crash or a wedged page
    kills only this throwaway process; the caller checkpoints the page as done
    and moves on rather than losing the whole book or crashing the server.
    """
    from . import pdf_worker

    fd, result_path = tempfile.mkstemp(prefix="sanctum_ocr_", suffix=".pkl")
    os.close(fd)
    proc = _MP_CONTEXT.Process(
        target=pdf_worker.ocr_page_main,
        args=(filepath, page_index, ocr.effective_languages(), result_path, dpi),
    )
    try:
        proc.start()
        poll_interval = 0.5
        elapsed = 0.0
        while proc.is_alive() and elapsed < _OCR_PAGE_TIMEOUT:
            proc.join(poll_interval)
            elapsed += poll_interval
            if should_stop and should_stop():
                proc.terminate()
                proc.join()
                return ""
        if proc.is_alive():
            logger.error(
                f"OCR page {page_index + 1} timed out after {_OCR_PAGE_TIMEOUT}s for {filepath}"
            )
            proc.terminate()
            proc.join()
            return ""
        if os.path.getsize(result_path) == 0:
            logger.error(
                f"OCR page {page_index + 1} worker crashed (exit {proc.exitcode}) for {filepath}"
            )
            return ""
        with open(result_path, "rb") as fh:
            return pickle.load(fh)
    finally:
        if proc.is_alive():
            proc.terminate()
            proc.join()
        try:
            os.unlink(result_path)
        except OSError as e:
            logger.debug("Failed to remove temp OCR result file %s: %s", result_path, e)


def book_page_count(filepath: str) -> int:
    doc = _fitz_open_with_timeout(filepath)
    try:
        return doc.page_count
    finally:
        doc.close()
