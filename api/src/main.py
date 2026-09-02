from contextlib import asynccontextmanager
from fastapi import FastAPI
from sqlalchemy import text
from .database import engine
from .models import Base
from .auth import router as auth_router
from .routers.library import router as library_router
from .routers.campaigns import router as campaigns_router
from .routers.invites import router as invites_router
from .routers.bot import router as bot_router
from .routers.assets import router as assets_router
from .routers.favorites import router as favorites_router
from . import book_indexing as indexing

# The Fuzion game-system module (per-system automation + its tables) is absent
# from the public open-core build. Everything Fuzion-specific hangs off this
# flag so the core app boots without it.
try:
    from .routers.fuzion import router as fuzion_router
    from . import models_fuzion  # noqa: F401 — registers the Fuzion tables on Base
    _HAS_FUZION = True
except ImportError:
    _HAS_FUZION = False

# Idempotent: add new columns to tables that already exist in production.
# create_all handles brand-new tables; these handle column additions on existing ones.
_ALTER_STMTS = [
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS allow_explicit BOOLEAN DEFAULT FALSE",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS password_hash TEXT",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS is_disabled BOOLEAN NOT NULL DEFAULT FALSE",
    "ALTER TABLE game_systems ADD COLUMN IF NOT EXISTS slug TEXT",
    "ALTER TABLE game_systems ADD COLUMN IF NOT EXISTS genre TEXT",
    "ALTER TABLE game_systems ADD COLUMN IF NOT EXISTS character_builder_url TEXT",
    "ALTER TABLE bookmarks ADD COLUMN IF NOT EXISTS page_number INTEGER",
    "ALTER TABLE bookmarks ADD COLUMN IF NOT EXISTS label TEXT",
    "ALTER TABLE bookmarks ADD COLUMN IF NOT EXISTS notes TEXT",
    "ALTER TABLE bookmarks ADD COLUMN IF NOT EXISTS selected_text TEXT",
    "ALTER TABLE campaign_members ADD COLUMN IF NOT EXISTS character_name TEXT",
    "ALTER TABLE campaign_members ADD COLUMN IF NOT EXISTS character_art_path TEXT",
    "ALTER TABLE campaign_members ADD COLUMN IF NOT EXISTS character_sheet_url TEXT",
    "ALTER TABLE wiki_pages ADD COLUMN IF NOT EXISTS parent_id TEXT REFERENCES wiki_pages(id) ON DELETE SET NULL",
    "ALTER TABLE wiki_pages ADD COLUMN IF NOT EXISTS slug TEXT",
    "ALTER TABLE wiki_pages ADD COLUMN IF NOT EXISTS sort_order INTEGER DEFAULT 0",
    "ALTER TABLE campaign_resources ADD COLUMN IF NOT EXISTS category_id TEXT",
    "ALTER TABLE campaign_resources ADD COLUMN IF NOT EXISTS sort_order INTEGER DEFAULT 0",
    # Remove old unique constraint on bookmarks (allow multiple bookmarks per book per user)
    "DROP INDEX IF EXISTS ix_bookmarks_user_book",
    "CREATE INDEX IF NOT EXISTS ix_bookmarks_user_book ON bookmarks (user_id, book_id)",
    # PDF indexing pipeline (own text extraction / OCR)
    "ALTER TABLE books ADD COLUMN IF NOT EXISTS indexed BOOLEAN NOT NULL DEFAULT FALSE",
    "ALTER TABLE books ADD COLUMN IF NOT EXISTS index_failed BOOLEAN NOT NULL DEFAULT FALSE",
    "ALTER TABLE books ADD COLUMN IF NOT EXISTS index_error TEXT NOT NULL DEFAULT ''",
    "ALTER TABLE books ADD COLUMN IF NOT EXISTS ocr_pending BOOLEAN NOT NULL DEFAULT FALSE",
    "ALTER TABLE books ADD COLUMN IF NOT EXISTS ocr_pages_done INTEGER NOT NULL DEFAULT 0",
    "ALTER TABLE books ADD COLUMN IF NOT EXISTS ocr_dpi INTEGER",
    "ALTER TABLE books ADD COLUMN IF NOT EXISTS is_missing BOOLEAN NOT NULL DEFAULT FALSE",
    # PDF map packs — a dedicated multi-page map viewer
    "ALTER TABLE maps ADD COLUMN IF NOT EXISTS mime_type TEXT",
    "ALTER TABLE maps ADD COLUMN IF NOT EXISTS page_count INTEGER",
    # Normalize any `tags` column holding a JSON scalar (e.g. the literal
    # `null`) to an empty array — jsonb_array_elements_text errors on scalars,
    # which broke GET /library/tags.
    "UPDATE books  SET tags = '[]'::json WHERE tags IS NOT NULL AND json_typeof(tags) <> 'array'",
    "UPDATE maps   SET tags = '[]'::json WHERE tags IS NOT NULL AND json_typeof(tags) <> 'array'",
    "UPDATE tokens SET tags = '[]'::json WHERE tags IS NOT NULL AND json_typeof(tags) <> 'array'",
    # Richer book/system metadata: ISBN, license, system family/parent
    "ALTER TABLE books ADD COLUMN IF NOT EXISTS isbn TEXT",
    "ALTER TABLE books ADD COLUMN IF NOT EXISTS license TEXT",
    "ALTER TABLE game_systems ADD COLUMN IF NOT EXISTS parent_id TEXT REFERENCES game_systems(id) ON DELETE SET NULL",
]

# Applied only when the Fuzion module is present (see _HAS_FUZION). create_all
# builds the fuzion_* tables fresh; these patch already-existing ones.
_FUZION_ALTER_STMTS = [
    # Campaign redesign: freeplay characters (no campaign) owned by a user
    "ALTER TABLE fuzion_characters ALTER COLUMN campaign_id DROP NOT NULL",
    "ALTER TABLE fuzion_characters ADD COLUMN IF NOT EXISTS owner_id INTEGER REFERENCES users(id) ON DELETE CASCADE",
    "CREATE INDEX IF NOT EXISTS ix_fuzion_chars_owner ON fuzion_characters (owner_id)",
    # Owner-toggleable GM edit access on Fuzion characters (delete stays owner-only)
    "ALTER TABLE fuzion_characters ADD COLUMN IF NOT EXISTS gm_can_edit BOOLEAN NOT NULL DEFAULT TRUE",
    # Combat lifecycle: a combat left unresolved can be parked out of the
    # current session and picked back up from the campaign Overview.
    "ALTER TABLE fuzion_combats ADD COLUMN IF NOT EXISTS is_parked BOOLEAN NOT NULL DEFAULT FALSE",
    # Economy rebuild: OP spent is authoritative on the row, not in data JSON.
    # Backfilled from data->>'op_spent' by scripts/backfill_fuzion_economy.py.
    "ALTER TABLE fuzion_characters ADD COLUMN IF NOT EXISTS op_spent INTEGER NOT NULL DEFAULT 0",
]


@asynccontextmanager
async def lifespan(app: FastAPI):
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        # FTS trigger for book search
        await conn.execute(text("""
            CREATE OR REPLACE FUNCTION books_search_vector_update() RETURNS trigger AS $$
            BEGIN
                NEW.search_vector :=
                    setweight(to_tsvector('english', coalesce(NEW.title, '')), 'A') ||
                    setweight(to_tsvector('english', coalesce(NEW.description, '')), 'B') ||
                    setweight(to_tsvector('english', coalesce(NEW.publisher, '')), 'C');
                RETURN NEW;
            END
            $$ LANGUAGE plpgsql;
        """))
        await conn.execute(text(
            "DROP TRIGGER IF EXISTS books_search_vector_update ON books;"
        ))
        await conn.execute(text("""
            CREATE TRIGGER books_search_vector_update
                BEFORE INSERT OR UPDATE ON books
                FOR EACH ROW EXECUTE FUNCTION books_search_vector_update();
        """))
        # FTS trigger for per-page book body text (real full-document search,
        # populated by book_indexing.index_book_text / ocr_book).
        await conn.execute(text("""
            CREATE OR REPLACE FUNCTION book_pages_search_vector_update() RETURNS trigger AS $$
            BEGIN
                NEW.search_vector := to_tsvector('english', coalesce(NEW.content, ''));
                RETURN NEW;
            END
            $$ LANGUAGE plpgsql;
        """))
        await conn.execute(text(
            "DROP TRIGGER IF EXISTS book_pages_search_vector_update ON book_pages;"
        ))
        await conn.execute(text("""
            CREATE TRIGGER book_pages_search_vector_update
                BEFORE INSERT OR UPDATE ON book_pages
                FOR EACH ROW EXECUTE FUNCTION book_pages_search_vector_update();
        """))
        for stmt in _ALTER_STMTS:
            await conn.execute(text(stmt))
        if _HAS_FUZION:
            for stmt in _FUZION_ALTER_STMTS:
                await conn.execute(text(stmt))

    indexing.start_background_scan(app)
    yield
    indexing.stop_background_scan(app)


app = FastAPI(title="Sanctum", lifespan=lifespan)

app.include_router(auth_router, prefix="/api")
app.include_router(library_router, prefix="/api")
app.include_router(campaigns_router, prefix="/api")
app.include_router(invites_router, prefix="/api")
app.include_router(bot_router, prefix="/api")
app.include_router(assets_router, prefix="/api")
app.include_router(favorites_router, prefix="/api")
if _HAS_FUZION:
    app.include_router(fuzion_router, prefix="/api")
