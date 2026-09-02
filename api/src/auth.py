import base64
import json
import secrets
from typing import Any
from datetime import datetime, timedelta, timezone
from urllib.parse import urlencode, urlsplit, urlunsplit
import httpx
from fastapi import APIRouter, Depends, HTTPException, Cookie, Response, Request
from fastapi.responses import RedirectResponse
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, delete, func
from .database import get_db
from .models import User, Session, UserPreference
from .config import settings
from .auth_local import hash_password, verify_password, local_uid, LOCAL_UID_PREFIX

router = APIRouter(prefix="/auth", tags=["auth"])

SESSION_TTL_DAYS = 30

# OIDC discovery document, fetched once from
# {oidc_issuer}/.well-known/openid-configuration and cached for the process.
_oidc_meta: dict | None = None


async def _oidc_metadata() -> dict:
    global _oidc_meta
    if _oidc_meta is None:
        issuer = settings.oidc_issuer.rstrip("/")
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(f"{issuer}/.well-known/openid-configuration")
            resp.raise_for_status()
            _oidc_meta = resp.json()
    return _oidc_meta


def _decode_jwt_claims(token: str | None) -> dict:
    """Best-effort decode of a JWT payload (no signature check — see caller)."""
    if not token or token.count(".") < 2:
        return {}
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception:
        return {}


def _with_origin(url: str, origin: str) -> str:
    """Return `url` with its scheme+host replaced by `origin` (path/query kept).

    Used for the browser authorize redirect when a reverse proxy fronts the IdP
    for per-domain theming (e.g. Authentik Brands)."""
    o = urlsplit(origin)
    u = urlsplit(url)
    return urlunsplit((o.scheme or u.scheme, o.netloc or u.netloc, u.path, u.query, u.fragment))


async def get_current_user(
    session_id: str | None = Cookie(default=None),
    db: AsyncSession = Depends(get_db),
) -> User:
    if not session_id:
        raise HTTPException(status_code=401, detail="Not authenticated")
    result = await db.execute(
        select(Session).where(
            Session.id == session_id,
            Session.expires_at > datetime.now(timezone.utc),
        )
    )
    session = result.scalar_one_or_none()
    if not session:
        raise HTTPException(status_code=401, detail="Session expired")
    result = await db.execute(select(User).where(User.id == session.user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=401, detail="User not found")
    if user.is_disabled:
        raise HTTPException(status_code=403, detail="This account has been disabled")

    # Throttled activity touch — only write if stale, so this doesn't turn
    # into a DB write on every single request. Feeds /auth/agent's "has
    # dracov been active recently" check.
    now = datetime.now(timezone.utc)
    if session.last_seen is None or (now - session.last_seen) > timedelta(minutes=5):
        session.last_seen = now
        await db.commit()

    return user


async def require_admin(user: User = Depends(get_current_user)) -> User:
    if not user.is_admin:
        raise HTTPException(status_code=403, detail="Admin only")
    return user


async def _mint_session(
    db: AsyncSession,
    user_id: int,
    response: Response,
    *,
    id_token: str | None = None,
) -> str:
    """Create a Session row and set the session_id cookie — the single path
    every login (Authentik, local password, agent) funnels through."""
    session_id = secrets.token_urlsafe(32)
    db.add(Session(
        id=session_id,
        user_id=user_id,
        expires_at=datetime.now(timezone.utc) + timedelta(days=SESSION_TTL_DAYS),
        id_token=id_token,
    ))
    await db.commit()
    response.set_cookie(
        "session_id", session_id,
        httponly=True, samesite="lax", max_age=SESSION_TTL_DAYS * 86400,
    )
    return session_id


# ── Auth mode discovery (frontend renders login UI from this) ────────────────

@router.get("/config")
async def auth_config():
    return {
        "mode": settings.auth_mode,
        "oidc_enabled": settings.oidc_enabled,
        "oidc_provider_name": settings.oidc_provider_name,
        "local_enabled": settings.local_enabled,
        "allow_registration": settings.local_enabled and settings.allow_registration,
    }


# ── Local username / password auth ──────────────────────────────────────────

class RegisterIn(BaseModel):
    username: str = Field(min_length=2, max_length=32)
    email: str | None = None
    password: str = Field(min_length=8, max_length=256)
    # A valid campaign invite token lets someone register even when open
    # registration is off (they were invited by a GM). The frontend then
    # calls POST /invites/{token}/accept to actually join.
    invite_token: str | None = None


class LoginIn(BaseModel):
    username: str
    password: str


@router.post("/register")
async def register(body: RegisterIn, response: Response, db: AsyncSession = Depends(get_db)):
    if not settings.local_enabled:
        raise HTTPException(status_code=404)
    if not settings.allow_registration:
        # An invite link is its own authorization to create an account.
        from .routers.invites import evaluate_invite
        _, _, reason = (
            await evaluate_invite(db, body.invite_token) if body.invite_token else (None, None, "no_invite")
        )
        if reason is not None:
            raise HTTPException(status_code=403, detail="Registration is disabled")
    username = body.username.strip()
    if not username or "/" in username or username.lower().startswith(LOCAL_UID_PREFIX):
        raise HTTPException(status_code=422, detail="Invalid username")

    uid = local_uid(username)
    clash = (await db.execute(
        select(User).where(
            (User.authentik_uid == uid) | (func.lower(User.username) == username.lower())
        )
    )).scalar_one_or_none()
    if clash:
        raise HTTPException(status_code=409, detail="That username is taken")

    # First account on a fresh instance bootstraps as admin.
    has_users = (await db.execute(select(User.id).limit(1))).first() is not None

    user = User(
        authentik_uid=uid,
        username=username,
        display_name=username,
        email=(body.email or "").strip() or None,
        password_hash=hash_password(body.password),
        is_admin=not has_users,
    )
    db.add(user)
    await db.flush()
    await _mint_session(db, user.id, response)
    return {"ok": True, "is_admin": user.is_admin}


class ChangePasswordIn(BaseModel):
    current_password: str = ""
    new_password: str = Field(min_length=8, max_length=256)


@router.post("/change-password")
async def change_password(
    body: ChangePasswordIn,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    if not settings.local_enabled:
        raise HTTPException(status_code=404)
    # Users with an existing local password must prove it; an OIDC account
    # setting a password for the first time (password_hash is NULL) doesn't.
    if user.password_hash and not verify_password(user.password_hash, body.current_password):
        raise HTTPException(status_code=403, detail="Current password is wrong")
    user.password_hash = hash_password(body.new_password)
    await db.commit()
    return {"ok": True}


@router.post("/login-local")
async def login_local(body: LoginIn, response: Response, db: AsyncSession = Depends(get_db)):
    if not settings.local_enabled:
        raise HTTPException(status_code=404)
    user = (await db.execute(
        select(User).where(
            func.lower(User.username) == body.username.strip().lower(),
            User.password_hash.is_not(None),
        )
    )).scalar_one_or_none()
    # Same generic error whether the user is missing or the password is wrong.
    if not user or not verify_password(user.password_hash, body.password):
        raise HTTPException(status_code=401, detail="Wrong username or password")
    if user.is_disabled:
        raise HTTPException(status_code=403, detail="This account has been disabled")
    await _mint_session(db, user.id, response)
    return {"ok": True}


# ── OpenID Connect (any provider) ───────────────────────────────────────────

@router.get("/login")
async def login():
    if not settings.oidc_enabled:
        raise HTTPException(status_code=404, detail="OIDC login is disabled")
    meta = await _oidc_metadata()
    authorize = meta["authorization_endpoint"]
    if settings.oidc_browser_origin:
        authorize = _with_origin(authorize, settings.oidc_browser_origin)
    params = {
        "client_id": settings.oidc_client_id,
        "redirect_uri": f"{settings.base_url}/api/auth/callback",
        "response_type": "code",
        "scope": settings.oidc_scopes,
    }
    sep = "&" if "?" in authorize else "?"
    return RedirectResponse(f"{authorize}{sep}{urlencode(params)}")


@router.get("/callback")
async def callback(code: str, db: AsyncSession = Depends(get_db)):
    if not settings.oidc_enabled:
        raise HTTPException(status_code=404, detail="OIDC login is disabled")
    meta = await _oidc_metadata()
    async with httpx.AsyncClient(timeout=15) as client:
        token_resp = await client.post(
            meta["token_endpoint"],
            data={
                "client_id": settings.oidc_client_id,
                "client_secret": settings.oidc_client_secret,
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": f"{settings.base_url}/api/auth/callback",
            },
        )
        token_resp.raise_for_status()
        token_data = token_resp.json()
        access_token = token_data["access_token"]
        id_token = token_data.get("id_token")

        userinfo_resp = await client.get(
            meta["userinfo_endpoint"],
            headers={"Authorization": f"Bearer {access_token}"},
        )
        userinfo_resp.raise_for_status()
        userinfo = userinfo_resp.json()

    # Merge id_token claims under the userinfo response. Some providers (e.g.
    # Authentik with include_claims_in_id_token) put `groups` only in the
    # id_token, not in /userinfo. The id_token came straight from the token
    # endpoint over TLS in this server-to-server call, so its claims are
    # trustworthy without re-verifying the signature.
    info = {**_decode_jwt_claims(id_token), **userinfo}

    # `sub` is the stable per-issuer subject id; stored in authentik_uid (a
    # legacy column name — it just holds "the external identity for this row").
    uid = info["sub"]
    username = info.get("preferred_username") or info.get("email") or uid
    # `.get("name", username)` only falls back on an absent claim, not an
    # empty-string one — some providers send name="" — so `or` is deliberate.
    display_name = info.get("name") or username
    email = info.get("email", "")
    groups = {str(g) for g in (info.get("groups") or [])}
    maps_admin = bool(settings.oidc_admin_group_set or settings.oidc_admin_email_set)
    is_admin = bool(groups & settings.oidc_admin_group_set) or (
        email.lower() in settings.oidc_admin_email_set
    )

    result = await db.execute(select(User).where(User.authentik_uid == uid))
    user = result.scalar_one_or_none()

    if not user:
        # With no group/email admin mapping configured, the first account on a
        # fresh instance bootstraps as admin (mirrors local registration).
        if not is_admin and not maps_admin:
            if (await db.execute(select(User.id).limit(1))).first() is None:
                is_admin = True
        user = User(
            authentik_uid=uid,
            username=username,
            display_name=display_name,
            email=email,
            is_admin=is_admin,
        )
        db.add(user)
        await db.flush()
    else:
        if user.is_disabled:
            raise HTTPException(status_code=403, detail="This account has been disabled")
        user.username = username
        user.display_name = display_name or user.display_name
        user.email = email
        # Only sync admin status from the IdP when an admin mapping is
        # configured; otherwise leave whatever an admin set in Sanctum.
        if maps_admin:
            user.is_admin = is_admin

    redirect = RedirectResponse(url="/", status_code=302)
    await _mint_session(db, user.id, redirect, id_token=id_token)
    return redirect


@router.get("/me")
async def me(user: User = Depends(get_current_user)):
    return {
        "id": user.id,
        "username": user.username,
        "display_name": user.display_name,
        "email": user.email,
        "is_admin": user.is_admin,
        # A local (password) account vs an OIDC one — the frontend shows the
        # change-password form only when this is true and local auth is on.
        "has_password": bool(user.password_hash),
        "local_auth": settings.local_enabled,
    }


class ProfileUpdate(BaseModel):
    display_name: str | None = Field(default=None, max_length=80)
    email: str | None = Field(default=None, max_length=254)


@router.patch("/me")
async def update_me(
    body: ProfileUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Self-service profile edit. For OIDC accounts the IdP re-syncs
    display_name / email on the next sign-in, so this sticks only until then."""
    if body.display_name is not None:
        name = body.display_name.strip()
        user.display_name = name or user.username
    if body.email is not None:
        user.email = body.email.strip() or None
    await db.commit()
    return {
        "id": user.id,
        "username": user.username,
        "display_name": user.display_name,
        "email": user.email,
        "is_admin": user.is_admin,
        "has_password": bool(user.password_hash),
        "local_auth": settings.local_enabled,
    }


# ── Per-user preferences (generic JSON KV, server-synced UI state) ──────────

_PREF_KEYS = {"library.presets"}  # allow-list so this can't be a scratch dump


@router.get("/me/preferences")
async def get_preferences(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    rows = (await db.execute(
        select(UserPreference).where(UserPreference.user_id == user.id)
    )).scalars().all()
    return {r.key: r.value for r in rows}


class PreferencePut(BaseModel):
    value: Any


@router.put("/me/preferences/{key}")
async def put_preference(
    key: str,
    body: PreferencePut,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    if key not in _PREF_KEYS:
        raise HTTPException(status_code=400, detail="Unknown preference key")
    row = (await db.execute(
        select(UserPreference).where(
            UserPreference.user_id == user.id, UserPreference.key == key
        )
    )).scalar_one_or_none()
    if row:
        row.value = body.value
    else:
        db.add(UserPreference(user_id=user.id, key=key, value=body.value))
    await db.commit()
    return {"ok": True, "key": key, "value": body.value}


# ── Admin: account management ───────────────────────────────────────────────

def _auth_kind(uid: str) -> str:
    if uid.startswith(LOCAL_UID_PREFIX):
        return "local"
    if uid.startswith("agent:"):
        return "agent"
    return "sso"


async def _admin_count(db: AsyncSession) -> int:
    return (await db.execute(
        select(func.count()).select_from(User).where(
            User.is_admin == True, User.is_disabled == False  # noqa: E712
        )
    )).scalar_one()


@router.get("/users")
async def list_users(
    db: AsyncSession = Depends(get_db),
    _: User = Depends(require_admin),
):
    users = (await db.execute(select(User).order_by(User.created_at))).scalars().all()
    # Campaigns owned, per user — surfaced so an admin knows what a delete takes
    # with it (Campaign.owner_id cascades).
    from .models import Campaign, CampaignMember
    owned = dict((await db.execute(
        select(Campaign.owner_id, func.count()).group_by(Campaign.owner_id)
    )).all())
    member = dict((await db.execute(
        select(CampaignMember.user_id, func.count()).group_by(CampaignMember.user_id)
    )).all())
    return [
        {
            "id": u.id,
            "username": u.username,
            "display_name": u.display_name,
            "email": u.email,
            "is_admin": u.is_admin,
            "is_disabled": u.is_disabled,
            "auth_kind": _auth_kind(u.authentik_uid),
            "has_password": bool(u.password_hash),
            "campaigns_owned": owned.get(u.id, 0),
            "campaigns_joined": member.get(u.id, 0),
            "created_at": u.created_at.isoformat() if u.created_at else None,
        }
        for u in users
    ]


class AdminUserUpdate(BaseModel):
    is_admin: bool | None = None
    is_disabled: bool | None = None


@router.patch("/users/{user_id}")
async def admin_update_user(
    user_id: int,
    body: AdminUserUpdate,
    db: AsyncSession = Depends(get_db),
    me: User = Depends(require_admin),
):
    target = await db.get(User, user_id)
    if not target:
        raise HTTPException(status_code=404, detail="User not found")
    if target.id == me.id:
        raise HTTPException(status_code=400, detail="You can't change your own admin or disabled status")

    # Guard the last active admin — don't let the instance lock itself out.
    if (body.is_admin is False or body.is_disabled is True) and target.is_admin and not target.is_disabled:
        if await _admin_count(db) <= 1:
            raise HTTPException(status_code=400, detail="This is the last active admin")

    if body.is_admin is not None:
        target.is_admin = body.is_admin
    if body.is_disabled is not None:
        target.is_disabled = body.is_disabled
        if body.is_disabled:
            # Kill their live sessions so the change takes effect immediately.
            await db.execute(delete(Session).where(Session.user_id == target.id))
    await db.commit()
    return {"ok": True, "id": target.id, "is_admin": target.is_admin, "is_disabled": target.is_disabled}


@router.delete("/users/{user_id}", status_code=204)
async def admin_delete_user(
    user_id: int,
    db: AsyncSession = Depends(get_db),
    me: User = Depends(require_admin),
):
    target = await db.get(User, user_id)
    if not target:
        raise HTTPException(status_code=404, detail="User not found")
    if target.id == me.id:
        raise HTTPException(status_code=400, detail="You can't delete your own account here")
    if target.is_admin and not target.is_disabled and await _admin_count(db) <= 1:
        raise HTTPException(status_code=400, detail="This is the last active admin")
    # Campaign.owner_id / memberships / sessions / bookmarks / favorites all
    # cascade on the FK — deleting the row is enough.
    await db.delete(target)
    await db.commit()


@router.get("/users/search")
async def search_users(
    q: str,
    db: AsyncSession = Depends(get_db),
    _: User = Depends(get_current_user),
):
    """Account search for the game roster (GM adds players by account, not free text)."""
    if len(q.strip()) < 2:
        return []
    pattern = f"%{q.strip()}%"
    rows = (await db.execute(
        select(User).where(
            (User.username.ilike(pattern) | User.display_name.ilike(pattern))
            # Agent accounts (see /auth/agent) aren't real players — keep
            # them out of the "add a player to this game" picker.
            & ~User.authentik_uid.ilike("agent:%")
        ).limit(10)
    )).scalars().all()
    return [{"id": u.id, "username": u.username, "display_name": u.display_name} for u in rows]


@router.post("/logout")
async def logout(
    response: Response,
    session_id: str | None = Cookie(default=None),
    db: AsyncSession = Depends(get_db),
):
    id_token = None
    if session_id:
        result = await db.execute(select(Session).where(Session.id == session_id))
        session = result.scalar_one_or_none()
        if session:
            id_token = session.id_token
            await db.delete(session)
            await db.commit()
    response.delete_cookie("session_id")

    # NOTE: this response is fetched via AJAX, not a full page navigation —
    # redirecting *this response* (e.g. to Authentik's end-session endpoint)
    # gets silently swallowed as a cross-origin fetch redirect, so the
    # frontend never sees it complete. A hidden iframe pointed at the same
    # URL doesn't work either (Authentik's session cookie isn't reliably sent
    # in that third-party context, and/or it may refuse to be framed) — it
    # silently no-ops. So instead we hand back the URL and the frontend does
    # a REAL top-level navigation there (see auth_provider.dart), which is
    # the only reliable way to actually terminate Authentik's own session
    # cookie. That matters because `prompt=login` on /auth/login only forces
    # re-authentication ONCE per underlying Authentik session (real Authentik
    # behavior — its re-trigger tracking flag never resets after first use),
    # so every sign-in after that first one silently reuses whichever
    # account is still live at the IdP without this.
    #
    # id_token_hint + post_logout_redirect_uri bounce the user straight back to
    # Sanctum once the IdP session is cleared. The provider must allow
    # {base_url} as a post-logout redirect URI. Local-password sessions have no
    # IdP to sign out of — the frontend just drops its state when
    # idp_logout_url is null (see auth_provider.dart).
    idp_logout_url = None
    if id_token and settings.oidc_enabled:
        try:
            end_session = (await _oidc_metadata()).get("end_session_endpoint")
        except Exception:
            end_session = None
        if end_session:
            params = {"id_token_hint": id_token}
            post_logout = settings.oidc_post_logout_redirect or settings.base_url
            if post_logout != "-":
                params["post_logout_redirect_uri"] = post_logout
            sep = "&" if "?" in end_session else "?"
            idp_logout_url = f"{end_session}{sep}{urlencode(params)}"
    return {"ok": True, "idp_logout_url": idp_logout_url}


# ── Agent login (bypasses Authentik entirely) ───────────────────────────────
#
# Lets an automation / QA agent authenticate without going through the full
# OAuth dance for every testing pass. Gated two ways:
# (1) a long random secret in the URL (AGENT_SECRET_KEY, unset = disabled),
# (2) only works while the real "dracov" account has been active in the last
# 3 hours (via Session.last_seen, see get_current_user above) — so the
# window this is usable in is tied to an actual human being at the keyboard,
# not permanently open. Both failure modes return an identical generic 404
# so a request with a wrong/guessed secret can't distinguish "wrong secret"
# from "right secret but dracov isn't active right now".

_AGENT_USERNAME = "agent"
_AGENT_AUTHENTIK_UID = "agent:automation"
_AGENT_SESSION_TTL_HOURS = 6
_AGENT_ACTIVITY_WINDOW_HOURS = 3


@router.get("/agent/{secret}")
async def agent_login(secret: str, db: AsyncSession = Depends(get_db)):
    not_found = HTTPException(status_code=404)

    if not settings.agent_secret_key or not secrets.compare_digest(secret, settings.agent_secret_key):
        raise not_found

    dracov = (await db.execute(
        select(User).where(User.username.ilike("dracov"))
    )).scalar_one_or_none()
    if not dracov:
        raise not_found

    cutoff = datetime.now(timezone.utc) - timedelta(hours=_AGENT_ACTIVITY_WINDOW_HOURS)
    recent_session = (await db.execute(
        select(Session).where(
            Session.user_id == dracov.id,
            Session.last_seen.is_not(None),
            Session.last_seen > cutoff,
        ).limit(1)
    )).scalar_one_or_none()
    if not recent_session:
        raise not_found

    agent_user = (await db.execute(
        select(User).where(User.authentik_uid == _AGENT_AUTHENTIK_UID)
    )).scalar_one_or_none()
    if not agent_user:
        agent_user = User(
            authentik_uid=_AGENT_AUTHENTIK_UID,
            username=_AGENT_USERNAME,
            display_name="Automation",
            is_admin=True,
        )
        db.add(agent_user)
        await db.flush()

    session_id = secrets.token_urlsafe(32)
    session = Session(
        id=session_id,
        user_id=agent_user.id,
        expires_at=datetime.now(timezone.utc) + timedelta(hours=_AGENT_SESSION_TTL_HOURS),
    )
    db.add(session)
    await db.commit()

    # Redirect into the app like a real login (/auth/callback does the same)
    # — hitting this URL directly in a browser should land you in Sanctum,
    # not show raw JSON. The session_id is still readable from the Set-Cookie
    # header for programmatic/curl use (e.g. `curl -D -` or a cookie jar).
    redirect = RedirectResponse(url="/", status_code=302)
    redirect.set_cookie(
        "session_id",
        session_id,
        httponly=True,
        samesite="lax",
        max_age=_AGENT_SESSION_TTL_HOURS * 3600,
    )
    return redirect


# ── Authentik webhook: force re-auth on username/password change ───────────
#
# Sanctum sessions live 30 days independent of Authentik's own session state
# (no refresh token, no mid-session revalidation) — so a rename or password
# change at the IdP could otherwise sit stale in Sanctum for up to a month.
# Authentik logs a `user_write` event for both; a Notification Rule there
# (filtered to that action) fires a webhook here, and we:
#   1. look up the changed user's *current* profile via Authentik's admin API
#      (using a token scoped to view_user only — see docs/authentik-webhook.md),
#   2. update the matching Sanctum user row (matched on the stable `uid`
#      field, which is exactly what's stored as authentik_uid — verified
#      directly against Authentik's DB, not just assumed from docs),
#   3. delete every active Sanctum session for that user, forcing a real
#      re-login (and thus a fresh sync) the next time they touch the app.
# Gated by a long random secret in the URL, same pattern as /auth/agent.

@router.post("/authentik-webhook/{secret}")
async def authentik_webhook(
    secret: str,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    if not settings.authentik_webhook_secret or not secrets.compare_digest(
        secret, settings.authentik_webhook_secret
    ):
        raise HTTPException(status_code=404)

    body = await request.json()
    # Authentik's default webhook body (no custom webhook_mapping_body
    # configured) is NOT the raw Event — it's the serialized Notification,
    # which has no "action"/"user.pk" fields at all. What it does reliably
    # give us: "event_user_username" — the *current* (post-write) username
    # of the user the event is about, which is exactly enough to look them
    # up. Verified against real deliveries, not guessed from docs — the
    # NotificationRule here is already filtered to action=user_write via its
    # bound Event Matcher Policy, so we don't need to re-check the action.
    username = body.get("event_user_username") or body.get("user_username")

    if not username:
        return {"ok": True, "skipped": True}

    async with httpx.AsyncClient() as client:
        resp = await client.get(
            f"{settings.authentik_base_url}/api/v3/core/users/",
            params={"username": username},
            headers={"Authorization": f"Bearer {settings.authentik_admin_token}"},
        )
        if resp.status_code != 200:
            # Don't 500 on a lookup failure — Authentik will just retry
            # deliveries per its own notification-transport policy, and a
            # dangling webhook shouldn't take the endpoint down.
            return {"ok": False, "reason": f"authentik lookup {resp.status_code}"}
        results = resp.json().get("results", [])
        info = results[0] if results else {}

    uid = info.get("uid")
    if not uid:
        return {"ok": False, "reason": "no uid in authentik response"}

    result = await db.execute(select(User).where(User.authentik_uid == uid))
    user = result.scalar_one_or_none()
    if not user:
        # Not a Sanctum account (or hasn't logged in here yet) — nothing to do.
        return {"ok": True, "matched": False}

    user.username = info.get("username", user.username)
    user.display_name = info.get("name") or user.display_name
    user.email = info.get("email", user.email)

    await db.execute(delete(Session).where(Session.user_id == user.id))
    await db.commit()

    return {"ok": True, "matched": True, "user_id": user.id, "sessions_cleared": True}
