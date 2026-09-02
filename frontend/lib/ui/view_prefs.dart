// Per-viewer view preferences (grid vs list, sort order) — a lightweight
// convenience persisted in localStorage. Not shared, not authoritative;
// falls back cleanly when storage is unavailable.
//
// Server-side named filter presets (the bigger [public] roadmap item) would
// layer on top of this, not replace it.

// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

String? _get(String key) {
  try {
    return html.window.localStorage[key];
  } catch (_) {
    return null;
  }
}

void _set(String key, String value) {
  try {
    html.window.localStorage[key] = value;
  } catch (_) {}
}

enum LibraryView { grid, list }

LibraryView readLibraryView() =>
    _get('sanctum_library_view') == 'list' ? LibraryView.list : LibraryView.grid;

void writeLibraryView(LibraryView v) =>
    _set('sanctum_library_view', v == LibraryView.list ? 'list' : 'grid');

enum SystemSort { name, books }

SystemSort readSystemSort() =>
    _get('sanctum_system_sort') == 'books' ? SystemSort.books : SystemSort.name;

void writeSystemSort(SystemSort s) =>
    _set('sanctum_system_sort', s == SystemSort.books ? 'books' : 'name');

/// Per-system book browser: list of rows (default) vs a grid of covers.
LibraryView readBookView() =>
    _get('sanctum_book_view') == 'grid' ? LibraryView.grid : LibraryView.list;

void writeBookView(LibraryView v) =>
    _set('sanctum_book_view', v == LibraryView.grid ? 'grid' : 'list');
