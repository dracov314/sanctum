// Sanctum Fuzion shared chrome — tokens and small shared widgets, sourced
// directly from the Sanctum Design System project (tokens.css,
// components/buttons-inputs.html, chips.html, panels.html, trackers.html)
// and the campaign-redesign handoff's shared JS style helpers
// (chipStyle/tabStyle/dieChipStyle/navItemStyle/roleStyle,
// Sanctum TTRPG App.dc.html ~L2411-2445).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/client.dart';
import 'web_upload_stub.dart' if (dart.library.html) 'web_upload_impl.dart';
export 'web_upload_stub.dart' if (dart.library.html) 'web_upload_impl.dart' show pickAndUpload, openExternal;

// A user's display_name can be an empty string (not null) when their OIDC
// provider sent a blank name claim — `?? username` alone doesn't catch that,
// since "" isn't null. Falls back to username, then to "" as a last resort.
String displayNameOf(Map<String, dynamic> u) {
  final dn = u['display_name'] as String?;
  if (dn != null && dn.isNotEmpty) return dn;
  return (u['username'] as String?) ?? '';
}

// ── Tokens (design-system/tokens.css) ───────────────────────────────────────

const kBg = Color(0xFF19130E);
const kNav = Color(0xFF241A12);
const kCard = Color(0xFF2C2016);
const kChipBox = Color(0xFF2A1D12);
const kWell = Color(0xFF1D140C);
const kInput = Color(0xFF140E09);
// Deeper input bg used specifically for session-room dice-roller controls
// (skill dropdown, NPC label/base fields, chat send box) — spec's #0F0902,
// distinct from the standard #140E09 form input bg above.
const kInputDeep = Color(0xFF0F0902);

const kBorder = Color(0xFF5A3E22);
const kBorderDim = Color(0xFF3A2917);

const kAccent = Color(0xFF8C2F2F);
const kAccentHover = Color(0xFFA83D3D);
const kBrass = Color(0xFFD4AF37);
const kLink = Color(0xFFD9B074);

// Body text ladder — rgba(230,215,190, alpha)
const kT100 = Color(0xFFE6D7BE);
const kT82 = Color(0xD1E6D7BE);
const kT68 = Color(0xADE6D7BE);
const kT55 = Color(0x8CE6D7BE);
const kT45 = Color(0x73E6D7BE);
const kT40 = Color(0x66E6D7BE); // used as a slightly-dimmer-than-45 hint tone
const kT50 = Color(0x80E6D7BE); // session-room roll math-line tone (rgba(...,0.5))

const kFail = Color(0xFFC1443B);
const kWarn = Color(0xFFD9822B);
const kSuccess = Color(0xFF7FA65C);
const kInfo = Color(0xFF5E8C86);
const kResist = Color(0xFFB5615A);
const kGmTag = Color(0xFFD9A441);
const kDiscord = Color(0xFF5865F2); // Discord brand blurple, used for the relayed-log "DISCORD" tag

// Parchment scroll (character sheet only)
const kParch1 = Color(0xFFEFE1BE);
const kParch2 = Color(0xFFE4D2A4);
const kParch3 = Color(0xFFE7D6AC);
const kInk = Color(0xFF3A2610);
const kInkMuted = Color(0xFF6B5230);
// Interactive text on the parchment sheet ("+ Add", inline actions) — a deep
// teal that reads as a link against the warm paper without the muddy
// red-on-tan of kAccent, and clearly distinct from the kInk / kInkMuted body
// tones. No underline needed.
const kParchLink = Color(0xFF2F6E63);
const kRodLight = Color(0xFF6B4A2A);
const kRodDark = Color(0xFF3E2A18);
// Ink-wash tones used for boxed stat rows/dividers on the parchment sheet —
// same #5A3E16 ink at three alphas (subtle fill, border, stronger fill).
const kParchWash = Color(0x145A3E16);
const kParchWashStrong = Color(0x265A3E16);
const kParchLine = Color(0x4D5A3E16);

// 'Georgia'/'serif' are safe here — a real installed font and a generic CSS
// family, neither of which Flutter Web's runtime Google-Fonts auto-fetch
// will try to satisfy over the network. 'Spectral' (a Google Font) used to
// sit in this fallback chain and was quietly relying on that same CDN fetch
// the Roboto bug above was fixed for — removed 2026-08-11, same reasoning.
const _serifFallback = ['Georgia', 'serif'];

/// Toggleable "fantasy scroll" look for the Fuzion character sheet — off by
/// default (screen-reader/dyslexia-friendly standard font), persisted to
/// localStorage so the choice survives a reload. IMFellEnglish is bundled
/// locally in pubspec.yaml, not a Google Fonts reference, for the same
/// self-hosted-independence reason as Roboto/the old Spectral fallback above.
const _fancyFontFamily = 'IMFellEnglish';
const _fancyFontFallback = ['Georgia', 'serif'];

bool _loadFancyFontPref() {
  try {
    return readLocalStorage('sanctum_fancy_font') == 'true';
  } catch (_) {
    return false;
  }
}

final fancyFontEnabled = ValueNotifier<bool>(_loadFancyFontPref());

void toggleFancyFont() {
  fancyFontEnabled.value = !fancyFontEnabled.value;
  try {
    writeLocalStorage('sanctum_fancy_font', fancyFontEnabled.value.toString());
  } catch (_) {}
}

TextStyle serif(double size, {FontWeight weight = FontWeight.w700, Color? color, double? ls}) =>
    TextStyle(
      fontFamily: fancyFontEnabled.value ? _fancyFontFamily : 'Georgia',
      fontFamilyFallback: fancyFontEnabled.value ? _fancyFontFallback : _serifFallback,
      fontSize: size, fontWeight: weight, color: color, letterSpacing: ls);

/// Small pill toggle for [fancyFontEnabled] — drop into any parchment-sheet
/// header. Rebuilds itself only (via ValueListenableBuilder), not the whole
/// sheet, but callers still need their own listener higher up if other text
/// on the page needs to react to the same flag (see DefaultTextStyle usage
/// in fuzion_session_room.dart / fuzion_characters.dart).
Widget fancyFontToggle() => ValueListenableBuilder<bool>(
      valueListenable: fancyFontEnabled,
      builder: (context, fancy, _) => InkWell(
        onTap: toggleFancyFont,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: kParchWashStrong,
            border: Border.all(color: kParchLine),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            fancy ? 'Scroll Font: On' : 'Scroll Font: Off',
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: kInkMuted),
          ),
        ),
      ),
    );

// ── GM/Player role resolution ───────────────────────────────────────────────
//
// The reference's top-bar PLAYER/GM chip is a Design-tool preview convenience
// with no real accounts behind it. Real GM status must come from actual
// campaign membership (`role`: owner|gm|player) — never a client-only toggle
// a regular player could flip to see hidden roll difficulties or GM-only
// journal entries. The chip is admin-only here and only changes how the UI
// *renders* for that admin's own session; the backend enforces real writes
// server-side regardless.

bool isGmRole(String? role) => role == 'owner' || role == 'gm';

final fuzionAdminPreviewProvider = StateProvider<String?>((ref) => null);

bool resolveIsGm(WidgetRef ref, {required bool realIsGm, required bool isAdmin}) {
  if (isAdmin) {
    final override = ref.watch(fuzionAdminPreviewProvider);
    if (override != null) return override == 'gm';
  }
  return realIsGm;
}

// ── Chrome scaffold ──────────────────────────────────────────────────────────

class PageChrome extends StatelessWidget {
  final Widget child;
  final double contentMaxWidth;
  // 980 left ~340px of dead margin on each side of a 1080p window. 1620 fills a
  // 1920 viewport (minus the 210px sidebar + 48px page padding → ~1662px of
  // content space) with just a small right-hand breathing gap, while still
  // capping line length on ultra-wide monitors so prose pages don't sprawl.
  // Individual screens can still pass a smaller value if their content wants
  // to stay narrow.
  const PageChrome({super.key, required this.child, this.contentMaxWidth = 1620});

  @override
  Widget build(BuildContext context) => Container(
        color: kBg,
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        // topLeft, not topCenter: page content hugs the sidebar instead of
        // floating in the middle with a dead gutter on both sides. The
        // maxWidth still caps line length on ultra-wide monitors.
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: contentMaxWidth),
            child: child,
          ),
        ),
      );
}

/// Responsive tile grid — as many [minTileWidth]-or-wider columns as fit the
/// available width, each stretched to fill its share of the row. Mirrors the
/// library's `repeat(auto-fill, minmax(Npx, 1fr))`; [itemBuilder] gets the
/// computed tile width so children can size themselves to it.
class TileGrid extends StatelessWidget {
  final int count;
  final Widget Function(int index, double tileWidth) itemBuilder;
  final double minTileWidth;
  final double spacing;
  const TileGrid({
    super.key,
    required this.count,
    required this.itemBuilder,
    this.minTileWidth = 320,
    this.spacing = 12,
  });
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final cols = ((c.maxWidth + spacing) / (minTileWidth + spacing)).floor().clamp(1, 999);
        final tileWidth = (c.maxWidth - spacing * (cols - 1)) / cols;
        return Wrap(spacing: spacing, runSpacing: spacing, children: [
          for (var i = 0; i < count; i++) itemBuilder(i, tileWidth),
        ]);
      });
}

/// The Sanctum hero banner (assets/sanctum_banner.jpeg, 3200×736 ≈ 4.35:1).
/// The frame matches the image aspect so the whole art always shows — no
/// cropped "Sanctum" ribbon. [maxWidth] defaults to unbounded so the banner
/// fills whatever width the page gives it; pass a finite value to cap it.
class SanctumBanner extends StatelessWidget {
  final double maxWidth;
  const SanctumBanner({super.key, this.maxWidth = double.infinity});
  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Container(
            decoration: BoxDecoration(
                color: kNav, border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(10)),
            padding: const EdgeInsets.all(14),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: AspectRatio(
                aspectRatio: 3200 / 736,
                child: Image.asset('assets/sanctum_banner.jpeg',
                    fit: BoxFit.cover, filterQuality: FilterQuality.medium),
              ),
            ),
          ),
        ),
      );
}

/// Standard top-of-screen header for a top-level route: hero banner, page
/// title, optional one-line subtitle, optional trailing action. Ends with its
/// own bottom spacing so callers can drop it straight in above their content.
class SanctumPageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  const SanctumPageHeader(this.title, {super.key, this.subtitle, this.trailing});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SanctumBanner(),
          const SizedBox(height: 24),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Flexible(child: Text(title, style: serif(20, color: kT100))),
            if (trailing != null) trailing!,
          ]),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: const TextStyle(fontSize: 11, color: kT55)),
          ],
          const SizedBox(height: 20),
        ],
      );
}

// ── Shared small widgets (design-system component catalog) ─────────────────

/// choice chip (components/chips.html ".choice"): 4px 10px, radius 14, 11px.
class ChoiceChipX extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const ChoiceChipX(this.label, this.active, this.onTap, {super.key});
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: active ? const Color(0x668C2F2F) : kCard,
            border: Border.all(color: active ? kAccent : kBorder),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(label, style: TextStyle(
              fontSize: 11, color: active ? Colors.white : kT82)),
        ),
      );
}

/// tabStyle(active): 12px 6px, 13px, bottom border 2px.
class RefTab extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const RefTab(this.label, this.active, this.onTap, {super.key});
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
          decoration: BoxDecoration(
              border: Border(bottom: BorderSide(
                  color: active ? kAccent : Colors.transparent, width: 2))),
          child: Text(label, style: TextStyle(fontSize: 13,
              fontWeight: active ? FontWeight.w700 : FontWeight.w600,
              color: active ? Colors.white : kT68)),
        ),
      );
}

/// navItemStyle(active): 9px 10px, radius 8, 11px 700/600.
class NavItem extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const NavItem(this.label, this.active, this.onTap, {super.key});
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: active ? const Color(0x668C2F2F) : kCard,
            border: Border.all(color: active ? kAccent : kBorder),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(label, style: TextStyle(fontSize: 11,
              fontWeight: active ? FontWeight.w700 : FontWeight.w600,
              color: active ? Colors.white : kT68)),
        ),
      );
}

/// roleStyle(active): 4px 12px, radius 14, 11px 700 — admin preview chip.
class RoleChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const RoleChip(this.label, this.active, this.onTap, {super.key});
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: active ? const Color(0x668C2F2F) : Colors.transparent,
            border: Border.all(color: active ? kAccent : kBorder),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
              color: active ? Colors.white : kT68)),
        ),
      );
}

/// dieChipStyle(kind): inline die-result chip — base/add/sub/max.
class DieChip extends StatelessWidget {
  final int value;
  final String kind; // base|add|sub|max
  const DieChip(this.value, {super.key, this.kind = 'base'});
  @override
  Widget build(BuildContext context) {
    final (bg, border, fg) = switch (kind) {
      'add' => (const Color(0x2E7FA65C), kSuccess, kSuccess),
      'sub' => (const Color(0x2EC1443B), kFail, kFail),
      'max' => (const Color(0x2ED4AF37), kBrass, kBrass),
      _ => (kChipBox, kBorder, kT82),
    };
    final prefix = kind == 'add' ? '+' : (kind == 'sub' ? '−' : '');
    // widthFactor:1 keeps the chip shrink-wrapped to the digit (+ minWidth) —
    // a plain `alignment: Alignment.center` expands it to fill whatever width
    // the parent Wrap offers, so a single die rendered as a full-width bar.
    return Container(
      constraints: const BoxConstraints(minWidth: 24),
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(color: bg, border: Border.all(color: border), borderRadius: BorderRadius.circular(5)),
      child: Center(
        widthFactor: 1,
        child: Text('$prefix$value', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fg)),
      ),
    );
  }
}

/// Section heading (components/panels.html ".section-header .t"): 11px 700
/// accent, 0.5px tracking, uppercase per spec copy.
class SectionHeading extends StatelessWidget {
  final String text;
  const SectionHeading(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: kAccent, letterSpacing: 0.5));
}

/// Field label (components/buttons-inputs.html ".field .l"): 10px, text-55,
/// 0.3px tracking.
class FieldLabel extends StatelessWidget {
  final String text;
  const FieldLabel(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(fontSize: 10, color: kT55, letterSpacing: 0.3));
}

/// Filled pill (components/buttons-inputs.html ".btn.filled"): bg accent,
/// radius 18, 8/16 padding, 13px 600.
/// compact=true matches the spec's small-pill variant (radius 14, 12/5, 11px)
/// used for the Advancement "Spend" / wizard "+Add" buttons.
class PillButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool compact;
  const PillButton(this.label, this.onTap, {super.key, this.compact = false});
  @override
  Widget build(BuildContext context) {
    final radius = compact ? 14.0 : 18.0;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        padding: compact
            ? const EdgeInsets.symmetric(horizontal: 12, vertical: 5)
            : const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(color: kAccent, borderRadius: BorderRadius.circular(radius)),
        child: Text(label, style: TextStyle(
            fontSize: compact ? 11 : 13, fontWeight: FontWeight.w600, color: Colors.white)),
      ),
    );
  }
}

/// Outlined pill (components/buttons-inputs.html ".btn.outlined"):
/// transparent, link-colored text, border.
class PillButtonOutlined extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool compact;
  const PillButtonOutlined(this.label, this.onTap, {super.key, this.compact = false});
  @override
  Widget build(BuildContext context) {
    final radius = compact ? 14.0 : 18.0;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        padding: compact
            ? const EdgeInsets.symmetric(horizontal: 12, vertical: 5)
            : const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(radius), border: Border.all(color: kBorder)),
        child: Text(label, style: TextStyle(
            fontSize: compact ? 11 : 13, fontWeight: FontWeight.w600, color: kLink)),
      ),
    );
  }
}

/// Mini button (components/buttons-inputs.html ".btn.mini"): bordered, 9px,
/// tag-style (e.g. "+ New Character").
class TagButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const TagButton(this.label, this.onTap, {super.key});
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(4)),
          child: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: kLink)),
        ),
      );
}

/// Star toggle backed by `/favorites` (book/map/token, see api/src/routers/
/// favorites.py). Optimistic: flips immediately on tap and reverts if the
/// request fails, rather than waiting on a round trip. [onChanged] fires
/// after a successful mutation so a caller with a "favorites only" filter
/// can invalidate its list provider — the fetched list's own `is_favorited`
/// snapshot goes stale the moment this button's local state diverges from
/// it, otherwise the filter silently hides items just starred/unstarred.
class FavoriteButton extends StatefulWidget {
  final String itemType;
  final String itemId;
  final bool initialValue;
  final double size;
  final VoidCallback? onChanged;
  const FavoriteButton({super.key, required this.itemType, required this.itemId, required this.initialValue, this.size = 20, this.onChanged});

  @override
  State<FavoriteButton> createState() => _FavoriteButtonState();
}

class _FavoriteButtonState extends State<FavoriteButton> {
  late bool _value = widget.initialValue;

  @override
  void didUpdateWidget(covariant FavoriteButton old) {
    super.didUpdateWidget(old);
    if (old.itemId != widget.itemId || old.initialValue != widget.initialValue) {
      _value = widget.initialValue;
    }
  }

  Future<void> _toggle() async {
    final next = !_value;
    setState(() => _value = next);
    try {
      if (next) {
        await apiPost('/favorites', {'item_type': widget.itemType, 'item_id': widget.itemId});
      } else {
        await apiDelete('/favorites/${widget.itemType}/${widget.itemId}');
      }
      widget.onChanged?.call();
    } catch (_) {
      if (mounted) setState(() => _value = !next);
    }
  }

  @override
  Widget build(BuildContext context) => Tooltip(
        message: _value ? 'Remove from favorites' : 'Add to favorites',
        child: InkWell(
          onTap: _toggle,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(_value ? Icons.star : Icons.star_border, size: widget.size, color: _value ? kAccent : kT100),
          ),
        ),
      );
}

/// Read/write tag pills for a book/map/token, backed by `PATCH
/// .../tags` (see api/src/routers/library.py's update_book_tags and
/// assets.py's update_map_tags/update_token_tags). Optimistic like
/// FavoriteButton: edits the local list immediately, reverts on failure.
/// [onChanged] fires after a successful save so a caller with a tag filter
/// can invalidate its list provider.
class TagEditor extends StatefulWidget {
  final String itemType; // 'book' | 'map' | 'token'
  final String itemId;
  final List<String> initialTags;
  final VoidCallback? onChanged;
  final bool compact;
  const TagEditor({super.key, required this.itemType, required this.itemId, required this.initialTags, this.onChanged, this.compact = false});

  @override
  State<TagEditor> createState() => _TagEditorState();
}

class _TagEditorState extends State<TagEditor> {
  late List<String> _tags = List.from(widget.initialTags);
  bool _adding = false;
  final _ctrl = TextEditingController();
  final _focus = FocusNode();

  @override
  void didUpdateWidget(covariant TagEditor old) {
    super.didUpdateWidget(old);
    if (old.itemId != widget.itemId) _tags = List.from(widget.initialTags);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  String get _endpoint => switch (widget.itemType) {
        'book' => '/library/books/${widget.itemId}/tags',
        'map' => '/assets/maps/${widget.itemId}/tags',
        'token' => '/assets/tokens/${widget.itemId}/tags',
        _ => throw ArgumentError('unknown tag itemType: ${widget.itemType}'),
      };

  Future<void> _save(List<String> next) async {
    final prev = _tags;
    setState(() => _tags = next);
    try {
      await apiPatch(_endpoint, {'tags': next});
      widget.onChanged?.call();
    } catch (_) {
      if (mounted) setState(() => _tags = prev);
    }
  }

  void _remove(String tag) => _save(_tags.where((t) => t != tag).toList());

  void _commitAdd() {
    final v = _ctrl.text.trim();
    _ctrl.clear();
    setState(() => _adding = false);
    if (v.isEmpty || _tags.any((t) => t.toLowerCase() == v.toLowerCase())) return;
    _save([..._tags, v]);
  }

  @override
  Widget build(BuildContext context) {
    final fontSize = widget.compact ? 9.0 : 10.0;
    return Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
      for (final t in _tags)
        Container(
          padding: EdgeInsets.symmetric(horizontal: widget.compact ? 6 : 8, vertical: widget.compact ? 2 : 3),
          decoration: BoxDecoration(color: kWell, border: Border.all(color: kBorderDim), borderRadius: BorderRadius.circular(10)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(t, style: TextStyle(fontSize: fontSize, color: kT82)),
            const SizedBox(width: 4),
            InkWell(onTap: () => _remove(t), child: Icon(Icons.close, size: fontSize + 2, color: kT55)),
          ]),
        ),
      if (_adding)
        SizedBox(
          width: 90,
          height: widget.compact ? 20 : 22,
          child: TextField(
            controller: _ctrl,
            focusNode: _focus,
            autofocus: true,
            style: TextStyle(fontSize: fontSize, color: Colors.white),
            decoration: const InputDecoration(
              isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              filled: true, fillColor: kInput, hintText: 'tag…',
              hintStyle: TextStyle(fontSize: 10, color: kT45),
              border: OutlineInputBorder(borderSide: BorderSide(color: kBorderDim)),
            ),
            onSubmitted: (_) => _commitAdd(),
            onTapOutside: (_) => _commitAdd(),
          ),
        )
      else
        InkWell(
          onTap: () => setState(() => _adding = true),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: widget.compact ? 6 : 8, vertical: widget.compact ? 2 : 3),
            decoration: BoxDecoration(border: Border.all(color: kBorderDim, style: BorderStyle.solid), borderRadius: BorderRadius.circular(10)),
            child: Icon(Icons.add, size: fontSize + 2, color: kT55),
          ),
        ),
    ]);
  }
}

/// Bordered text input (components/buttons-inputs.html ".field .in"): 26px
/// compact field, #140E09 bg by default.
class RefInput extends StatelessWidget {
  final TextEditingController controller;
  final String? hint;
  final double? width;
  final int maxLines;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Color bg;
  const RefInput(this.controller, {super.key, this.hint, this.width, this.maxLines = 1, this.onChanged, this.onSubmitted, this.bg = kInput});
  @override
  Widget build(BuildContext context) {
    final field = Container(
      height: maxLines == 1 ? 26 : null,
      decoration: BoxDecoration(color: bg, border: Border.all(color: kBorderDim), borderRadius: BorderRadius.circular(3)),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        maxLines: maxLines,
        style: const TextStyle(fontSize: 11, color: Colors.white),
        decoration: InputDecoration(
          hintText: hint, hintStyle: const TextStyle(fontSize: 11, color: kT40),
          border: InputBorder.none, isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        ),
      ),
    );
    return width != null ? SizedBox(width: width, child: field) : field;
  }
}

/// Dashed rounded-rect border painter — Flutter has no built-in dashed
/// BoxBorder, and the spec calls for `border: 1px dashed` in a couple of
/// placeholder-tile contexts.
class DashedRRectBorder extends StatelessWidget {
  final Widget child;
  final double radius;
  final Color color;
  const DashedRRectBorder({super.key, required this.child, this.radius = 8, this.color = kBorder});
  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _DashedRRectPainter(radius: radius, color: color), child: child);
}

class _DashedRRectPainter extends CustomPainter {
  final double radius;
  final Color color;
  _DashedRRectPainter({required this.radius, required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius));
    final path = Path()..addRRect(rrect);
    final paint = Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 1;
    const dashWidth = 4.0, dashGap = 3.0;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        canvas.drawPath(metric.extractPath(distance, distance + dashWidth), paint);
        distance += dashWidth + dashGap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRectPainter oldDelegate) =>
      oldDelegate.radius != radius || oldDelegate.color != color;
}

/// Placeholder image slot ("Portrait"/"Cover" etc): dashed-ish bordered box,
/// icon + label + "or browse files" sub-line. No real upload backend —
/// portrait/cover/map upload is explicitly out of scope per the handoff.
class ImageSlot extends StatelessWidget {
  final double width, height;
  final String shape; // rect|rounded|circle|pill
  final double radius;
  final String placeholder;
  const ImageSlot({super.key, required this.width, required this.height,
      this.shape = 'rounded', this.radius = 12, this.placeholder = 'Drop an image'});

  BorderRadius get _br => switch (shape) {
        'circle' => BorderRadius.circular(1000),
        'pill' => BorderRadius.circular(height / 2),
        'rect' => BorderRadius.zero,
        _ => BorderRadius.circular(radius),
      };

  @override
  Widget build(BuildContext context) => Container(
        width: width, height: height,
        decoration: BoxDecoration(color: const Color(0x475A3E22), borderRadius: _br,
            border: Border.all(color: const Color(0x59E6D7BE), width: 1.5)),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.image_outlined, size: 22, color: kT68.withValues(alpha: 0.72)),
            const SizedBox(height: 4),
            Text(placeholder, style: const TextStyle(fontSize: 13, color: kT68), textAlign: TextAlign.center),
            const Text.rich(TextSpan(children: [
              TextSpan(text: 'or ', style: TextStyle(fontSize: 11, color: kT55)),
              TextSpan(text: 'browse files', style: TextStyle(fontSize: 11, color: kT55, decoration: TextDecoration.underline)),
            ]), textAlign: TextAlign.center),
          ]),
        ),
      );
}

