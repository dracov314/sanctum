"""Best-effort outbound notifications via self-hosted ntfy.

A failed notification must never break the request that triggered it — every
call swallows its own errors, same policy as the Authentik webhook in auth.py.
"""
import logging

import httpx

from .config import settings

log = logging.getLogger("sanctum.notify")


async def ntfy(
    title: str,
    message: str,
    *,
    tags: str = "",
    priority: str = "default",
    click: str = "",
) -> None:
    """POST a notification to ntfy_topic. No-op if ntfy_url is unset."""
    if not settings.ntfy_url:
        return
    headers = {"Title": title, "Priority": priority}
    if tags:
        headers["Tags"] = tags
    if click:
        headers["Click"] = click
    if settings.ntfy_token:
        headers["Authorization"] = f"Bearer {settings.ntfy_token}"
    url = f"{settings.ntfy_url.rstrip('/')}/{settings.ntfy_topic}"
    try:
        async with httpx.AsyncClient(timeout=8.0) as client:
            await client.post(url, content=message.encode("utf-8"), headers=headers)
    except Exception as exc:  # noqa: BLE001 - notifications are never critical
        log.warning("ntfy notify failed (%s): %s", url, exc)
