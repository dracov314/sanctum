"""Shared constants for the library indexer package.

Timeouts and the spawn multiprocessing context, scoped to what the book
library needs (PDFs only — no comic-archive/audio support).
"""
import multiprocessing

_FITZ_TIMEOUT = 30  # seconds — files that can't be opened in 30s are unreadable
_DB_TIMEOUT = 30  # seconds — max time to wait for a DB operation before treating it as hung

# Wall-clock budget for extracting text from a single PDF in the isolated
# worker process. Generous because OCR of a large scanned book is slow; a file
# that can't finish in this window is treated as unindexable rather than
# allowed to stall the scan forever.
_EXTRACT_TIMEOUT = 1800  # seconds (30 min)

# Per-page OCR budget for the deferred-OCR worker. OCR is checkpointed per
# page, so the whole-book budget doesn't apply to scanned PDFs — only a single
# wedged page is abandoned after this, and the book continues to the next page.
_OCR_PAGE_TIMEOUT = 120  # seconds

_THUMBNAIL_TIMEOUT = 30  # seconds

# Spawn (not fork) a fresh interpreter for the extraction worker. The API
# process runs an asyncio event loop and holds asyncpg connections; forking
# that state into a child is unsafe, whereas spawn re-imports this module
# cleanly with no inherited locks or file handles.
_MP_CONTEXT = multiprocessing.get_context("spawn")
