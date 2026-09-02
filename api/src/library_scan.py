"""Book discovery scan: find new PDFs on disk, register them, flag missing ones.

Own implementation.py + categories.py + metadata.py (the
book-relevant slice only — a fuller scan would also cover maps/tokens/audio, but this
assets.py already has its own discovery scan for maps/tokens, and there's no
Sanctum audio feature).

This is what actually answers "the library is scanned periodically for new
PDFs": book_indexing.py's background loop only (re-)processes Book rows that
already exist in Postgres; this module is the step before that — walking
/library/books/<system>/... to notice files with no row yet, and flagging rows
whose file has since vanished from disk.

Three manual-scan modes:
  - "new"     (default): register new files, flag/unflag missing ones, leave
              existing rows' metadata untouched.
  - "missing": also fill empty metadata fields from a sidecar .opf file.
  - "replace": also overwrite metadata fields wherever a sidecar .opf provides
              a value.
Sidecar files are optional — with none present (as of writing, this library
has zero .opf files), "missing"/"replace" behave identically to "new".
"""
import logging
import os
import re
from pathlib import Path
from typing import Optional
from xml.etree import ElementTree

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .config import settings
from .models import Book, GameSystem

logger = logging.getLogger("sanctum.library_scan")

METADATA_MODES = ("new", "missing", "replace")

# ── Category inference (Own implementation.py) ───────

CATEGORY_MAP = {
    "core": ["core", "rulebook", "rules", "phb", "dmg", "mm", "basic"],
    "supplement": ["supplement", "expansion", "sourcebook", "guide", "companion"],
    "adventure": ["adventure", "module", "campaign", "scenario", "quest"],
    "character-sheet": ["character sheet", "charsheet"],
    "map": ["map", "battlemap", "battle map", "dungeon map"],
    "handout": ["handout", "reference", "cheat", "quick ref", "screen"],
    "homebrew": ["homebrew", "custom", "house rules"],
    "starter-set": ["starter set", "starter kit", "beginner box", "boxed set", "essentials"],
}
UNCATEGORIZED = "uncategorized"
_SYSTEM_AGNOSTIC_SLUGS = frozenset({"system-agnostic", "generic", "any"})


def slugify(name: str) -> str:
    slug = name.lower().strip()
    slug = re.sub(r"[^\w\s-]", "", slug)
    slug = re.sub(r"[\s_]+", "-", slug)
    slug = re.sub(r"-+", "-", slug)
    return slug.strip("-")


def is_system_agnostic_folder(folder_name: str) -> bool:
    return slugify(folder_name) in _SYSTEM_AGNOSTIC_SLUGS


def _normalize_folder(name: str) -> str:
    return re.sub(r"[-_\s]+", " ", name.lower()).strip()


def _token_matches_keyword(token: str, kw_token: str) -> bool:
    if token == kw_token:
        return True
    if token == kw_token + "s":
        return True
    if token == kw_token + "es":
        return True
    if kw_token.endswith("y") and token == kw_token[:-1] + "ies":
        return True
    return False


def _keyword_matches(keyword: str, tokens: list[str]) -> bool:
    kw_tokens = keyword.split()
    n = len(kw_tokens)
    for i in range(len(tokens) - n + 1):
        if all(_token_matches_keyword(tokens[i + j], kw_tokens[j]) for j in range(n)):
            return True
    return False


def _match_category(segment: str) -> Optional[str]:
    tokens = _normalize_folder(segment).split()
    for category, keywords in CATEGORY_MAP.items():
        if any(_keyword_matches(kw, tokens) for kw in keywords):
            return category
    return None


def guess_category(relative_path: str) -> str:
    """Infer book category from path segments (relative to the library root).

    The top-level category folder (the first folder under the system root,
    e.g. "core" in "books/Shadowrun/core/Companions/x.pdf") takes priority; if
    it doesn't match a keyword, its name is used verbatim as a custom category.
    """
    segments = relative_path.replace("\\", "/").split("/")
    folder_segments = segments[:-1]  # drop the filename
    if len(folder_segments) > 2:
        top_category_folder = folder_segments[2]
        matched = _match_category(top_category_folder)
        if matched is not None:
            return matched
        return slugify(top_category_folder)
    for segment in reversed(folder_segments):
        matched = _match_category(segment)
        if matched is not None:
            return matched
    return "core"


def agnostic_category(relative_path: str) -> str:
    parts = relative_path.replace("\\", "/").split("/")
    if len(parts) > 3:
        return slugify(parts[2])
    return UNCATEGORIZED


# ── OPF sidecar metadata (Own implementation.py) ───────

_OPF_NS = {
    "dc": "http://purl.org/dc/elements/1.1/",
    "opf": "http://www.idpf.org/2007/opf",
}
_OPF_BOOK_FIELDS = ("title", "authors", "description", "publisher", "year", "tags")


def parse_opf_metadata(opf_path: str) -> dict:
    """Parse a Calibre/OPF sidecar file; returns whichever fields it provides."""
    try:
        tree = ElementTree.parse(opf_path)
    except Exception as e:
        logger.warning(f"Could not parse OPF file '{opf_path}': {e}")
        return {}

    root = tree.getroot()
    meta: dict = {}

    def _find_text(tag: str) -> str:
        el = root.find(f"opf:metadata/dc:{tag}", _OPF_NS)
        return el.text.strip() if el is not None and el.text else ""

    title = _find_text("title")
    if title:
        meta["title"] = title

    authors = [
        author
        for el in root.findall("opf:metadata/dc:creator", _OPF_NS)
        if el.text and (author := el.text.strip()) and author.lower() != "unknown"
    ]
    if authors:
        meta["authors"] = authors

    description = _find_text("description")
    if description:
        description = re.sub(r"<[^>]+>", "", description).strip()
        if description:
            meta["description"] = description

    publisher = _find_text("publisher")
    if publisher:
        meta["publisher"] = publisher

    date_str = _find_text("date")
    if date_str:
        try:
            year = int(date_str[:4])
            if year > 1000:
                meta["year"] = year
        except (ValueError, IndexError):
            pass

    subjects = [
        el.text.strip().lower()
        for el in root.findall("opf:metadata/dc:subject", _OPF_NS)
        if el.text and el.text.strip()
    ]
    if subjects:
        meta["tags"] = subjects

    cover_ref = root.find("opf:guide/opf:reference[@type='cover']", _OPF_NS)
    if cover_ref is not None:
        href = cover_ref.get("href", "")
        if href:
            meta["cover_image_filename"] = Path(href).name

    return meta


def _find_opf_meta(root: str, filename: str) -> dict:
    """Sibling <stem>.opf first, then a shared metadata.opf in the same folder."""
    opf_path = os.path.join(root, Path(filename).stem + ".opf")
    if not os.path.isfile(opf_path):
        opf_path = os.path.join(root, "metadata.opf")
    return parse_opf_metadata(opf_path) if os.path.isfile(opf_path) else {}


def _apply_opf_to_book(book: Book, opf_meta: dict, mode: str) -> bool:
    """mode="missing": fill only empty fields. mode="replace": overwrite whenever provided."""
    if not opf_meta or mode not in ("missing", "replace"):
        return False
    changed = False
    for field in _OPF_BOOK_FIELDS:
        if field not in opf_meta:
            continue
        new_value = opf_meta[field]
        if mode == "missing" and getattr(book, field, None):
            continue
        if getattr(book, field, None) != new_value:
            setattr(book, field, new_value)
            changed = True
    return changed


def _title_from_filename(filename: str) -> str:
    return Path(filename).stem.replace("_", " ").replace("-", " ").strip()


# ── Discovery walk + missing-file reconciliation ────────────────────────────

def _walk_book_files(books_dir: Path):
    """Yield (root, filename, relative_path) for every .pdf under books_dir."""
    for root, dirs, files in os.walk(books_dir):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        opf_cover_filenames: set[str] = set()
        for f in files:
            if Path(f).suffix.lower() == ".opf":
                cover_fn = parse_opf_metadata(os.path.join(root, f)).get("cover_image_filename")
                if cover_fn:
                    opf_cover_filenames.add(cover_fn)
        for filename in sorted(files):
            if filename.startswith(".") or filename in opf_cover_filenames:
                continue
            if Path(filename).suffix.lower() != ".pdf":
                continue
            filepath = os.path.join(root, filename)
            relative_path = os.path.relpath(filepath, settings.library_path)
            yield root, filename, relative_path


async def scan_new_books(db: AsyncSession, metadata_mode: str = "new") -> dict:
    """Walk /library/books/<system>/... registering new files and updating metadata.

    Returns a stats dict: new_systems, new_books, updated_books, errors.
    """
    if metadata_mode not in METADATA_MODES:
        raise ValueError(f"metadata_mode must be one of {METADATA_MODES}")

    books_dir = Path(settings.library_path) / "books"
    stats = {"new_systems": 0, "new_books": 0, "updated_books": 0, "errors": 0}
    if not books_dir.exists():
        return stats

    system_cache: dict[str, GameSystem] = {}

    for system_dir in sorted(p for p in books_dir.iterdir() if p.is_dir() and not p.name.startswith(".")):
        system_name = system_dir.name
        system_slug = slugify(system_name)
        is_agnostic = is_system_agnostic_folder(system_name)

        system = system_cache.get(system_slug)
        if system is None:
            # Match by slug OR name: systems imported by the original data
            # migration never had `slug` populated, so a slug-only lookup
            # would never find them and would create a duplicate.
            system = (await db.execute(
                select(GameSystem).where(
                    (GameSystem.slug == system_slug) | (GameSystem.name == system_name)
                )
            )).scalar_one_or_none()
            if system is not None:
                if not system.slug:
                    system.slug = system_slug
                    await db.commit()
            if system is None:
                system = GameSystem(id=system_slug, name=system_name, slug=system_slug)
                db.add(system)
                try:
                    await db.commit()
                    stats["new_systems"] += 1
                    logger.info(f"Found a new game system: {system_name}")
                except Exception:
                    await db.rollback()
                    stats["errors"] += 1
                    continue
            system_cache[system_slug] = system

        for root, filename, relative_path in _walk_book_files(system_dir):
            try:
                existing = (
                    await db.execute(select(Book).where(Book.filepath == relative_path))
                ).scalar_one_or_none()

                opf_meta = _find_opf_meta(root, filename) if metadata_mode in ("missing", "replace") else {}

                if existing:
                    if _apply_opf_to_book(existing, opf_meta, metadata_mode):
                        await db.commit()
                        stats["updated_books"] += 1
                    continue

                category = agnostic_category(relative_path) if is_agnostic else guess_category(relative_path)
                full_opf_meta = opf_meta or _find_opf_meta(root, filename)
                filepath = os.path.join(root, filename)
                try:
                    file_size = os.path.getsize(filepath)
                except OSError:
                    logger.warning(f"Cannot stat file, skipping: {filepath}")
                    continue

                book = Book(
                    game_system_id=system.id,
                    title=full_opf_meta.get("title") or _title_from_filename(filename),
                    filename=filename,
                    filepath=relative_path,
                    category=category,
                    file_size=file_size,
                    mime_type="application/pdf",
                    authors=full_opf_meta.get("authors"),
                    description=full_opf_meta.get("description"),
                    publisher=full_opf_meta.get("publisher"),
                    year=full_opf_meta.get("year"),
                    tags=full_opf_meta.get("tags"),
                )
                db.add(book)
                await db.commit()
                stats["new_books"] += 1
                logger.info(f"Added book: {book.title} ({category}) in {system_name}")
            except Exception:
                logger.exception(f"Unexpected error registering '{filename}'")
                await db.rollback()
                stats["errors"] += 1

    await _reconcile_missing_books(db)
    return stats


async def _reconcile_missing_books(db: AsyncSession) -> int:
    """Flag books whose file is gone from disk; clear the flag for ones that reappeared."""
    books = (await db.execute(select(Book))).scalars().all()
    changed = 0
    for book in books:
        path = Path(settings.library_path) / book.filepath
        gone = not path.exists()
        if gone != book.is_missing:
            book.is_missing = gone
            changed += 1
            if gone:
                logger.warning(f"Missing book: '{book.title}' ({book.filepath})")
    if changed:
        await db.commit()
    return changed
