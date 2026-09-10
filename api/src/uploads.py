"""Shared helper for reading an uploaded file with a hard size ceiling.

Every upload endpoint funnels through `read_upload_capped` so a single request
can't exhaust RAM / fill the disk. The cap is checked twice: against the
declared Content-Length up front (cheap early-out for honest clients) and again
while streaming (defends against a lying / chunked-encoding client).
"""
from fastapi import HTTPException, UploadFile

_CHUNK = 1 << 20  # 1 MiB


async def read_upload_capped(file: UploadFile, max_mb: int) -> bytes:
    limit = max_mb * 1024 * 1024
    declared = getattr(file, "size", None)
    if declared is not None and declared > limit:
        raise HTTPException(413, f"File is too large (max {max_mb} MB)")

    out = bytearray()
    while chunk := await file.read(_CHUNK):
        out.extend(chunk)
        if len(out) > limit:
            raise HTTPException(413, f"File is too large (max {max_mb} MB)")
    return bytes(out)
