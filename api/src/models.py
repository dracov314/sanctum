import uuid
from sqlalchemy import (
    Column, Integer, Text, Boolean, ForeignKey, DateTime,
    BigInteger, JSON, Index
)
from sqlalchemy.dialects.postgresql import TSVECTOR
from sqlalchemy.orm import relationship
from sqlalchemy.sql import func
from .database import Base


def new_uuid():
    return str(uuid.uuid4())


# ── Auth ──────────────────────────────────────────────────────────────────────

class User(Base):
    __tablename__ = "users"
    id = Column(Integer, primary_key=True)
    # OIDC subject for Authentik-backed accounts; the synthetic value
    # "local:<username>" for local-password accounts (public open-core build).
    authentik_uid = Column(Text, unique=True, nullable=False, index=True)
    # argon2 hash — set only for local accounts, NULL for OIDC ones.
    password_hash = Column(Text, nullable=True)
    username = Column(Text, nullable=False)
    display_name = Column(Text)
    email = Column(Text)
    is_admin = Column(Boolean, default=False)
    # An admin can disable an account without deleting it — the user keeps their
    # data / campaign membership but every request fails auth until re-enabled.
    is_disabled = Column(Boolean, default=False, nullable=False)
    allow_explicit = Column(Boolean, default=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    bookmarks = relationship("Bookmark", back_populates="user", cascade="all, delete")
    favorites = relationship("Favorite", back_populates="user", cascade="all, delete")
    campaign_memberships = relationship("CampaignMember", back_populates="user", cascade="all, delete")


class UserPreference(Base):
    """Generic per-user JSON store, keyed by a dotted string. Backs
    server-synced UI preferences (saved library view presets, and whatever
    else wants to follow a user across devices)."""
    __tablename__ = "user_preferences"
    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    key = Column(Text, nullable=False)
    value = Column(JSON, nullable=False, default=dict)
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

    __table_args__ = (
        Index("ix_user_preferences_unique", "user_id", "key", unique=True),
    )


class Session(Base):
    __tablename__ = "sessions"
    id = Column(Text, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    expires_at = Column(DateTime(timezone=True), nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    # OIDC id_token from the original Authentik token exchange — kept so
    # /auth/logout can pass it as id_token_hint when sending the browser to
    # Authentik's end-session endpoint (required for post_logout_redirect_uri
    # to be honored, see auth.py).
    id_token = Column(Text, nullable=True)
    # Bumped (throttled) on every authenticated request — lets /auth/agent
    # gate agent-login access on "has dracov been active recently".
    last_seen = Column(DateTime(timezone=True), nullable=True)


# ── Library ───────────────────────────────────────────────────────────────────

class GameSystem(Base):
    __tablename__ = "game_systems"
    id = Column(Text, primary_key=True)
    name = Column(Text, nullable=False)
    slug = Column(Text)
    genre = Column(Text)
    character_builder_url = Column(Text)
    # Groups related systems/editions under a shared parent (e.g. "D&D 3.5e"
    # and "D&D 5e" both pointing at a "D&D" row). No cycle detection —
    # hierarchies here are realistically one level deep.
    parent_id = Column(Text, ForeignKey("game_systems.id", ondelete="SET NULL"), nullable=True)
    books = relationship("Book", back_populates="game_system")


class Book(Base):
    __tablename__ = "books"
    id = Column(Text, primary_key=True, default=new_uuid)
    game_system_id = Column(Text, ForeignKey("game_systems.id"), nullable=True)
    title = Column(Text, nullable=False)
    filename = Column(Text, nullable=False)
    filepath = Column(Text, nullable=False, unique=True)
    category = Column(Text)
    description = Column(Text)
    authors = Column(JSON)
    publisher = Column(Text)
    publisher_url = Column(Text)
    isbn = Column(Text)
    license = Column(Text)
    year = Column(Integer)
    file_size = Column(BigInteger)
    page_count = Column(Integer)
    mime_type = Column(Text)
    has_thumbnail = Column(Boolean, default=False)
    tags = Column(JSON)
    is_explicit = Column(Boolean, default=False)
    search_vector = Column(TSVECTOR)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

    # ── PDF indexing state (own pipeline, own pipeline) ────────────────
    indexed = Column(Boolean, default=False, nullable=False)
    index_failed = Column(Boolean, default=False, nullable=False)
    index_error = Column(Text, default="", nullable=False)
    ocr_pending = Column(Boolean, default=False, nullable=False)
    ocr_pages_done = Column(Integer, default=0, nullable=False)
    ocr_dpi = Column(Integer, nullable=True)  # per-book override; None = global default
    is_missing = Column(Boolean, default=False, nullable=False)  # file no longer on disk

    game_system = relationship("GameSystem", back_populates="books")
    bookmarks = relationship("Bookmark", back_populates="book", cascade="all, delete")
    pages = relationship("BookPage", back_populates="book", cascade="all, delete")

    __table_args__ = (
        Index("ix_books_search", "search_vector", postgresql_using="gin"),
        Index("ix_books_game_system", "game_system_id"),
        Index("ix_books_category", "category"),
    )


class BookPage(Base):
    """One page's extracted text, for real full-document search (not just metadata).

    Populated by book_indexing.index_book_text / ocr_book — native text-layer
    extraction or, for scanned books, per-page OCR. search_vector lets a single
    book's contents be searched page-by-page (see /library/books/{id}/search).
    """
    __tablename__ = "book_pages"
    id = Column(Integer, primary_key=True)
    book_id = Column(Text, ForeignKey("books.id", ondelete="CASCADE"), nullable=False)
    page_number = Column(Integer, nullable=False)
    content = Column(Text, nullable=False, default="")
    search_vector = Column(TSVECTOR)

    book = relationship("Book", back_populates="pages")

    __table_args__ = (
        Index("ix_book_pages_book_page", "book_id", "page_number", unique=True),
        Index("ix_book_pages_search", "search_vector", postgresql_using="gin"),
    )


class Bookmark(Base):
    __tablename__ = "bookmarks"
    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    book_id = Column(Text, ForeignKey("books.id", ondelete="CASCADE"), nullable=False)
    page_number = Column(Integer)
    label = Column(Text)
    notes = Column(Text)
    selected_text = Column(Text)
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    user = relationship("User", back_populates="bookmarks")
    book = relationship("Book", back_populates="bookmarks")

    __table_args__ = (
        Index("ix_bookmarks_user_book", "user_id", "book_id"),
    )


class Favorite(Base):
    __tablename__ = "favorites"
    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    item_type = Column(Text, nullable=False)  # "book" | "map" | "token"
    item_id = Column(Text, nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    user = relationship("User", back_populates="favorites")

    __table_args__ = (
        Index("ix_favorites_user_item", "user_id", "item_type", "item_id", unique=True),
    )


# ── Assets ────────────────────────────────────────────────────────────────────

class Map(Base):
    __tablename__ = "maps"
    id = Column(Text, primary_key=True, default=new_uuid)
    filename = Column(Text, nullable=False)
    filepath = Column(Text, nullable=False, unique=True)  # relative to library/maps/
    description = Column(Text)
    tags = Column(JSON, default=list)
    map_type = Column(Text)
    grid_size = Column(Text)
    file_size = Column(BigInteger)
    folder = Column(Text)  # relative folder path
    mime_type = Column(Text)
    # Set for PDF maps (a multi-page map pack); NULL means a single image.
    page_count = Column(Integer)
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    __table_args__ = (Index("ix_maps_folder", "folder"),)


class Token(Base):
    __tablename__ = "tokens"
    id = Column(Text, primary_key=True, default=new_uuid)
    filename = Column(Text, nullable=False)
    filepath = Column(Text, nullable=False, unique=True)  # relative to library/tokens/
    description = Column(Text)
    tags = Column(JSON, default=list)
    is_explicit = Column(Boolean, default=False)
    file_size = Column(BigInteger)
    folder = Column(Text)
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    __table_args__ = (Index("ix_tokens_folder", "folder"),)


# ── Campaigns ─────────────────────────────────────────────────────────────────

class Campaign(Base):
    __tablename__ = "campaigns"
    id = Column(Text, primary_key=True, default=new_uuid)
    name = Column(Text, nullable=False)
    description = Column(Text)
    game_system_id = Column(Text, ForeignKey("game_systems.id"), nullable=True)
    owner_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    is_private = Column(Boolean, default=True)
    banner_url = Column(Text)
    settings = Column(JSON, nullable=True, default=lambda: {})
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

    owner = relationship("User", foreign_keys=[owner_id])
    members = relationship("CampaignMember", back_populates="campaign", cascade="all, delete")
    session_notes = relationship("SessionNote", back_populates="campaign", cascade="all, delete")
    wiki_pages = relationship("WikiPage", back_populates="campaign", cascade="all, delete")
    resources = relationship("CampaignResource", back_populates="campaign", cascade="all, delete")
    categories = relationship("CampaignCategory", back_populates="campaign", cascade="all, delete")
    files = relationship("CampaignFile", back_populates="campaign", cascade="all, delete")


class CampaignMember(Base):
    __tablename__ = "campaign_members"
    id = Column(Integer, primary_key=True)
    campaign_id = Column(Text, ForeignKey("campaigns.id", ondelete="CASCADE"), nullable=False)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    role = Column(Text, nullable=False, default="player")  # "gm" | "player"
    character_name = Column(Text)
    character_art_path = Column(Text)
    character_sheet_url = Column(Text)
    joined_at = Column(DateTime(timezone=True), server_default=func.now())

    campaign = relationship("Campaign", back_populates="members")
    user = relationship("User", back_populates="campaign_memberships")
    player_notes = relationship("PlayerSessionNote", back_populates="member", cascade="all, delete")

    __table_args__ = (
        Index("ix_campaign_members_unique", "campaign_id", "user_id", unique=True),
    )


class CampaignInvite(Base):
    """A GM-generated link that lets someone join a campaign without an admin
    creating their account first. The token is the shareable secret."""
    __tablename__ = "campaign_invites"
    id = Column(Text, primary_key=True, default=new_uuid)
    campaign_id = Column(Text, ForeignKey("campaigns.id", ondelete="CASCADE"), nullable=False)
    token = Column(Text, nullable=False, unique=True, index=True)
    created_by_id = Column(Integer, ForeignKey("users.id", ondelete="SET NULL"), nullable=True)
    role = Column(Text, nullable=False, default="player")  # "player" | "gm"
    max_uses = Column(Integer, nullable=True)  # NULL = unlimited
    uses = Column(Integer, nullable=False, default=0)
    expires_at = Column(DateTime(timezone=True), nullable=True)
    is_revoked = Column(Boolean, nullable=False, default=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    campaign = relationship("Campaign")
    created_by = relationship("User")

    __table_args__ = (Index("ix_campaign_invites_campaign", "campaign_id"),)


class SessionPoll(Base):
    """A "when can everyone play" poll. The GM proposes candidate slots
    (options, held as JSON so deleting one never reindexes responses); members
    mark yes / maybe / no per slot; the GM confirms one."""
    __tablename__ = "session_polls"
    id = Column(Text, primary_key=True, default=new_uuid)
    campaign_id = Column(Text, ForeignKey("campaigns.id", ondelete="CASCADE"), nullable=False)
    created_by_id = Column(Integer, ForeignKey("users.id", ondelete="SET NULL"), nullable=True)
    title = Column(Text, nullable=False)
    note = Column(Text)
    status = Column(Text, nullable=False, default="open")  # "open" | "confirmed" | "closed"
    # [{"id": "<uuid>", "starts_at": "<iso8601>"}], ordered.
    options = Column(JSON, nullable=False, default=list)
    confirmed_option_id = Column(Text, nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    campaign = relationship("Campaign")
    responses = relationship("SessionPollResponse", back_populates="poll", cascade="all, delete")

    __table_args__ = (Index("ix_session_polls_campaign", "campaign_id"),)


class SessionPollResponse(Base):
    __tablename__ = "session_poll_responses"
    id = Column(Integer, primary_key=True)
    poll_id = Column(Text, ForeignKey("session_polls.id", ondelete="CASCADE"), nullable=False)
    option_id = Column(Text, nullable=False)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    availability = Column(Text, nullable=False, default="yes")  # "yes" | "maybe" | "no"
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

    poll = relationship("SessionPoll", back_populates="responses")

    __table_args__ = (
        Index("ix_poll_responses_unique", "poll_id", "option_id", "user_id", unique=True),
    )


class CampaignCategory(Base):
    __tablename__ = "campaign_categories"
    id = Column(Text, primary_key=True, default=new_uuid)
    campaign_id = Column(Text, ForeignKey("campaigns.id", ondelete="CASCADE"), nullable=False)
    name = Column(Text, nullable=False)
    icon = Column(Text)
    sort_order = Column(Integer, default=0)
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    campaign = relationship("Campaign", back_populates="categories")

    __table_args__ = (Index("ix_campaign_categories_campaign", "campaign_id"),)


class CampaignFile(Base):
    __tablename__ = "campaign_files"
    id = Column(Text, primary_key=True, default=new_uuid)
    campaign_id = Column(Text, ForeignKey("campaigns.id", ondelete="CASCADE"), nullable=False)
    stored_path = Column(Text, nullable=False)
    filename = Column(Text, nullable=False)
    mime_type = Column(Text)
    size_bytes = Column(BigInteger)
    is_image = Column(Boolean, default=True)
    uploaded_by_id = Column(Integer, ForeignKey("users.id", ondelete="SET NULL"), nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    campaign = relationship("Campaign", back_populates="files")

    __table_args__ = (Index("ix_campaign_files_campaign", "campaign_id"),)


class SessionNote(Base):
    __tablename__ = "session_notes"
    id = Column(Text, primary_key=True, default=new_uuid)
    campaign_id = Column(Text, ForeignKey("campaigns.id", ondelete="CASCADE"), nullable=False)
    author_id = Column(Integer, ForeignKey("users.id", ondelete="SET NULL"), nullable=True)
    session_number = Column(Integer, nullable=False)
    title = Column(Text, nullable=False)
    content = Column(Text, default="")  # shared notes visible to all
    is_gm_only = Column(Boolean, default=False)
    is_active = Column(Boolean, default=False, nullable=False)
    xp_awarded = Column(Integer, default=0, nullable=False)
    ended_at = Column(DateTime(timezone=True), nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

    campaign = relationship("Campaign", back_populates="session_notes")
    author = relationship("User")
    gm_notes = relationship("GMSessionNote", back_populates="session", uselist=False, cascade="all, delete")
    player_notes = relationship("PlayerSessionNote", back_populates="session", cascade="all, delete")

    __table_args__ = (
        Index("ix_session_notes_campaign", "campaign_id", "session_number"),
    )


class GMSessionNote(Base):
    """GM-only private notes per session, separate from the shared session narrative."""
    __tablename__ = "gm_session_notes"
    id = Column(Integer, primary_key=True)
    session_id = Column(Text, ForeignKey("session_notes.id", ondelete="CASCADE"), nullable=False, unique=True)
    private_notes = Column(Text, default="")  # never shown to players
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

    session = relationship("SessionNote", back_populates="gm_notes")


class PlayerSessionNote(Base):
    """Each player's personal notes for a session (visible only to themselves)."""
    __tablename__ = "player_session_notes"
    id = Column(Integer, primary_key=True)
    session_id = Column(Text, ForeignKey("session_notes.id", ondelete="CASCADE"), nullable=False)
    member_id = Column(Integer, ForeignKey("campaign_members.id", ondelete="CASCADE"), nullable=False)
    content = Column(Text, default="")
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

    session = relationship("SessionNote", back_populates="player_notes")
    member = relationship("CampaignMember", back_populates="player_notes")

    __table_args__ = (
        Index("ix_player_notes_session_member", "session_id", "member_id", unique=True),
    )


class WikiPage(Base):
    __tablename__ = "wiki_pages"
    id = Column(Text, primary_key=True, default=new_uuid)
    campaign_id = Column(Text, ForeignKey("campaigns.id", ondelete="CASCADE"), nullable=False)
    author_id = Column(Integer, ForeignKey("users.id", ondelete="SET NULL"), nullable=True)
    parent_id = Column(Text, ForeignKey("wiki_pages.id", ondelete="SET NULL"), nullable=True)
    title = Column(Text, nullable=False)
    slug = Column(Text)
    content = Column(Text, default="")
    is_gm_only = Column(Boolean, default=False)
    sort_order = Column(Integer, default=0)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

    campaign = relationship("Campaign", back_populates="wiki_pages")
    author = relationship("User")

    __table_args__ = (Index("ix_wiki_pages_campaign", "campaign_id"),)


class WikiTemplate(Base):
    """A named, reusable content snippet a member can start a new wiki page
    from. Flat (no parent_id) — templates are standalone text, not pages."""
    __tablename__ = "wiki_templates"
    id = Column(Text, primary_key=True, default=new_uuid)
    campaign_id = Column(Text, ForeignKey("campaigns.id", ondelete="CASCADE"), nullable=False)
    author_id = Column(Integer, ForeignKey("users.id", ondelete="SET NULL"), nullable=True)
    name = Column(Text, nullable=False)
    content = Column(Text, default="")
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    author = relationship("User")

    __table_args__ = (Index("ix_wiki_templates_campaign", "campaign_id"),)


# ── Session Room log (generic — chat / dice / system events) ─────────────────
#
# Fuzion's character/combat tables moved to models_fuzion.py so the core app
# can run without the per-system automation. This one stays: the bot and the
# campaign code use it, and it's system-agnostic despite the legacy name.

class FuzionSessionLog(Base):
    """Session Room activity log: chat, dice rolls, system events.

    kind: chat | roll | system.  source: app | discord (bot relay, future).
    payload carries the full roll breakdown for kind=roll so history keeps
    every die face (design handoff lesson #2)."""
    __tablename__ = "fuzion_session_logs"
    id = Column(Text, primary_key=True, default=new_uuid)
    campaign_id = Column(Text, ForeignKey("campaigns.id", ondelete="CASCADE"), nullable=False)
    author_name = Column(Text, nullable=False, default="")
    kind = Column(Text, nullable=False, default="chat")
    source = Column(Text, nullable=False, default="app")
    payload = Column(JSON, nullable=False, default=dict)
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    __table_args__ = (Index("ix_fuzion_logs_campaign", "campaign_id", "created_at"),)


class CampaignResource(Base):
    __tablename__ = "campaign_resources"
    id = Column(Text, primary_key=True, default=new_uuid)
    campaign_id = Column(Text, ForeignKey("campaigns.id", ondelete="CASCADE"), nullable=False)
    name = Column(Text, nullable=False)
    resource_type = Column(Text, nullable=False)  # "link" | "book"
    url = Column(Text)
    book_id = Column(Text, ForeignKey("books.id", ondelete="SET NULL"), nullable=True)
    category_id = Column(Text, ForeignKey("campaign_categories.id", ondelete="SET NULL"), nullable=True)
    sort_order = Column(Integer, default=0)
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    campaign = relationship("Campaign", back_populates="resources")
    book = relationship("Book")
    category = relationship("CampaignCategory")
