import httpx
from .config import SANCTUM_API_URL, BOT_API_KEY

_HEADERS = {"X-Bot-Key": BOT_API_KEY}


class SanctumAPIError(Exception):
    def __init__(self, status: int, detail: str):
        self.status = status
        self.detail = detail
        super().__init__(f"Sanctum API {status}: {detail}")


async def _check(resp: httpx.Response) -> dict:
    if resp.status_code >= 400:
        try:
            detail = resp.json().get("detail", resp.text)
        except Exception:
            detail = resp.text
        raise SanctumAPIError(resp.status_code, detail)
    if resp.status_code == 204 or not resp.content:
        return {}
    return resp.json()


async def find_campaign(name: str) -> dict:
    async with httpx.AsyncClient() as c:
        r = await c.get(f"{SANCTUM_API_URL}/bot/campaigns", params={"name": name}, headers=_HEADERS)
        return await _check(r)


async def start_session(campaign_name: str, guild_id: str) -> dict:
    async with httpx.AsyncClient() as c:
        r = await c.post(
            f"{SANCTUM_API_URL}/bot/sessions/start",
            json={"campaign_name": campaign_name, "guild_id": guild_id},
            headers=_HEADERS,
        )
        return await _check(r)


async def end_session(session_id: str, summary: str | None = None) -> dict:
    async with httpx.AsyncClient() as c:
        r = await c.patch(
            f"{SANCTUM_API_URL}/bot/sessions/{session_id}/end",
            json={"session_id": session_id, "summary": summary},
            headers=_HEADERS,
        )
        return await _check(r)


async def add_note(session_id: str, content: str, is_gm_only: bool = False) -> dict:
    async with httpx.AsyncClient() as c:
        r = await c.post(
            f"{SANCTUM_API_URL}/bot/sessions/{session_id}/notes",
            json={"session_id": session_id, "content": content, "is_gm_only": is_gm_only},
            headers=_HEADERS,
        )
        return await _check(r)


async def set_roll_channel(guild_id: str, channel_id: str, campaign_name: str | None = None) -> dict:
    async with httpx.AsyncClient() as c:
        r = await c.post(
            f"{SANCTUM_API_URL}/bot/campaigns/roll-channel",
            json={"guild_id": guild_id, "campaign_name": campaign_name, "channel_id": channel_id},
            headers=_HEADERS,
        )
        return await _check(r)


async def list_roll_channels() -> list[dict]:
    async with httpx.AsyncClient() as c:
        r = await c.get(f"{SANCTUM_API_URL}/bot/roll-channels", headers=_HEADERS)
        result = await _check(r)
        return result if isinstance(result, list) else []


_PORTRAIT_EXT = {"image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/gif": "gif"}


async def get_character_portrait(char_id: str) -> tuple[bytes, str] | None:
    """(image bytes, file extension) for a character's primary album image, or
    None if it has no portrait. Raises SanctumAPIError/httpx.HTTPError on
    transport/other failures so callers can fall back gracefully."""
    async with httpx.AsyncClient() as c:
        r = await c.get(f"{SANCTUM_API_URL}/bot/characters/{char_id}/portrait", headers=_HEADERS)
        if r.status_code == 404:
            return None
        if r.status_code >= 400:
            raise SanctumAPIError(r.status_code, r.text)
        ct = r.headers.get("content-type", "image/jpeg").split(";")[0].strip()
        return r.content, _PORTRAIT_EXT.get(ct, "jpg")


async def get_recent_rolls(campaign_id: str, since_id: str | None = None) -> list[dict]:
    async with httpx.AsyncClient() as c:
        params = {"since_id": since_id} if since_id else {}
        r = await c.get(
            f"{SANCTUM_API_URL}/bot/campaigns/{campaign_id}/rolls",
            params=params, headers=_HEADERS,
        )
        result = await _check(r)
        return result if isinstance(result, list) else []
