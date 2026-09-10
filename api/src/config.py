import logging

from pydantic import AliasChoices, Field
from pydantic_settings import BaseSettings

log = logging.getLogger("sanctum.config")


class Settings(BaseSettings):
    postgres_password: str
    discord_bot_token: str = ""   # Lorekeeper bot only
    secret_key: str
    base_url: str            # https://sanctum.example.com

    # Authentication mode: "local" (username/password only — public open-core
    # default), "oidc" (any OpenID Connect provider), or "both". The OIDC routes
    # and the local register/login routes are each mounted only when their mode
    # allows.
    auth_mode: str = "both"
    allow_registration: bool = True   # gates POST /auth/register

    # ── Generic OpenID Connect (any compliant provider) ──────────────────────
    # Endpoints are discovered from {oidc_issuer}/.well-known/openid-configuration
    # so no provider-specific URLs are hardcoded. The AUTHENTIK_* env names are
    # kept as aliases for backward compatibility.
    oidc_issuer: str = Field(
        default="",
        validation_alias=AliasChoices("oidc_issuer", "authentik_issuer"),
    )
    oidc_client_id: str = Field(
        default="",
        validation_alias=AliasChoices("oidc_client_id", "authentik_client_id"),
    )
    oidc_client_secret: str = Field(
        default="",
        validation_alias=AliasChoices("oidc_client_secret", "authentik_client_secret"),
    )
    oidc_scopes: str = "openid profile email"
    oidc_provider_name: str = "SSO"        # login button: "Sign in with {name}"
    oidc_admin_groups: str = ""            # comma-separated; a matching `groups` claim value → admin
    oidc_admin_emails: str = ""            # comma list; a matching email → admin
    # Optional: origin (scheme://host) to use for the *browser* authorize
    # redirect only, when a reverse proxy fronts the IdP for per-domain theming
    # (e.g. Authentik Brands). Token/userinfo exchange still uses oidc_issuer.
    oidc_browser_origin: str = ""
    # Where the IdP sends the browser after RP-initiated logout. Must be
    # registered as a post-logout / logout redirect URI on the provider or some
    # IdPs (Authentik) reject the request. Default = base_url; set to "-" to
    # omit it (the user lands on the IdP's own logged-out page instead).
    oidc_post_logout_redirect: str = ""

    # Authentik "user_write" webhook (optional, Authentik-specific) — forces a
    # Sanctum re-login after a rename/password change at the IdP.
    authentik_base_url: str = ""  # https://id.example.com
    # Per-file upload ceilings (MiB). Campaign files / banners / character
    # sheets / wiki-markdown share the first; admin book-PDF uploads the second.
    max_upload_mb: int = 25
    max_book_upload_mb: int = 300
    # Who can pull a raw library PDF / a whole-system ZIP:
    #   "admin"  — admins only (default; reading still open to everyone via the
    #              server-rendered page images)
    #   "all"    — any signed-in user (a trusted private instance)
    library_download_policy: str = "admin"
    library_path: str = "/library"
    thumbnails_path: str = "/thumbnails"  # legacy pre-migration thumbnails, read-only fallback
    book_thumbnails_path: str = "/data/book_thumbnails"  # Sanctum's own generated thumbnails
    page_cache_path: str = "/data/page_cache"  # rendered reader page images (webp)
    campaign_files_path: str = "/data/campaign_files"
    bot_api_key: str = ""

    # ── Service / automation account (optional) ──────────────────────────────
    # A machine login for CI, monitoring, or an assistant working on the
    # instance. Everything here is off unless both secrets below are set.
    # See docs — GET /auth/automation/{secret}.
    automation_secret_key: str = Field(
        default="",
        validation_alias=AliasChoices("automation_secret_key", "agent_secret_key"),
    )
    # The login window is tied to this anchor account having a live session in
    # the last few hours (a human at the keyboard). Unset ⇒ off even with a
    # secret set. Set to your own username.
    automation_activity_username: str = Field(
        default="",
        validation_alias=AliasChoices("automation_activity_username", "agent_activity_username"),
    )
    # Access level for the service account: "user" (default, non-admin),
    # "admin" (instance admin). "dev" (admin + a diagnostics namespace) is
    # reserved for a later release — set now, it warns and falls back to "user".
    automation_account_role: str = "user"

    authentik_webhook_secret: str = ""  # gates POST /auth/authentik-webhook/{secret}
    authentik_admin_token: str = ""     # read-only (view_user only) service-account token, for the webhook's user lookup

    # Outbound ntfy notifications (self-hosted). Blank ntfy_url = disabled.
    # ntfy_url is the internal container address (http://ntfy) when api is
    # attached to the ntfy_default network, else the public https URL.
    ntfy_url: str = ""
    ntfy_token: str = ""
    ntfy_topic: str = "sanctum-uploads"

    @property
    def database_url(self) -> str:
        return f"postgresql+asyncpg://sanctum:{self.postgres_password}@postgres:5432/sanctum"

    @property
    def oidc_enabled(self) -> bool:
        return (
            self.auth_mode in ("oidc", "both")
            and bool(self.oidc_issuer)
            and bool(self.oidc_client_id)
        )

    @property
    def local_enabled(self) -> bool:
        return self.auth_mode in ("local", "both")

    @property
    def oidc_admin_group_set(self) -> set[str]:
        # Comma-separated only — group names can contain spaces
        # (e.g. Authentik's default "authentik Admins").
        return {g.strip() for g in self.oidc_admin_groups.split(",") if g.strip()}

    @property
    def oidc_admin_email_set(self) -> set[str]:
        return {e.strip().lower() for e in self.oidc_admin_emails.split(",") if e.strip()}

    @property
    def automation_account_is_admin(self) -> bool:
        """Resolve automation_account_role to an is_admin flag for the account.
        'dev' is not available yet — warn and treat as the least-privileged
        'user' rather than silently granting admin."""
        role = (self.automation_account_role or "user").strip().lower()
        if role == "admin":
            return True
        if role == "dev":
            log.warning(
                "AUTOMATION_ACCOUNT_ROLE='dev' is not available yet "
                "(the diagnostics tooling ships in a later release); the "
                "service account is running as 'user'. Set 'admin' if you "
                "need elevated access now."
            )
            return False
        return False

    class Config:
        env_file = ".env"


settings = Settings()
