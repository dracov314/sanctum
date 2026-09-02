from pydantic import AliasChoices, Field
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    postgres_password: str
    discord_bot_token: str = ""   # Lorekeeper bot only
    secret_key: str
    base_url: str            # https://sanctum.untrustedhub.wtf

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
    library_path: str = "/library"
    thumbnails_path: str = "/thumbnails"  # legacy pre-migration thumbnails, read-only fallback
    book_thumbnails_path: str = "/data/book_thumbnails"  # Sanctum's own generated thumbnails
    page_cache_path: str = "/data/page_cache"  # rendered reader page images (webp)
    campaign_files_path: str = "/data/campaign_files"
    bot_api_key: str = ""
    agent_secret_key: str = ""  # gates GET /auth/agent/{secret}, see auth.py
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

    class Config:
        env_file = ".env"


settings = Settings()
