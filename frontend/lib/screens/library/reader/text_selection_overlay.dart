import 'package:flutter/material.dart';
import '../../../ui/chrome.dart';

/// Draws a highlight rect over each word in the active selection range,
/// scaled from PDF-point space (the word boxes' native coordinates) to
/// whatever size this painter is actually given.
class _WordHighlightPainter extends CustomPainter {
  final List<Map<String, dynamic>> words;
  final double pageWidth;
  final double pageHeight;
  final int? startIdx;
  final int? endIdx;

  _WordHighlightPainter({
    required this.words,
    required this.pageWidth,
    required this.pageHeight,
    required this.startIdx,
    required this.endIdx,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (startIdx == null || endIdx == null) return;
    final lo = startIdx! <= endIdx! ? startIdx! : endIdx!;
    final hi = startIdx! <= endIdx! ? endIdx! : startIdx!;
    final sx = size.width / pageWidth;
    final sy = size.height / pageHeight;
    final paint = Paint()..color = kAccent.withValues(alpha: 0.35);
    for (var i = lo; i <= hi && i < words.length; i++) {
      final w = words[i];
      final rect = Rect.fromLTRB(
        (w['x0'] as num).toDouble() * sx,
        (w['y0'] as num).toDouble() * sy,
        (w['x1'] as num).toDouble() * sx,
        (w['y1'] as num).toDouble() * sy,
      ).inflate(1);
      canvas.drawRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WordHighlightPainter oldDelegate) =>
      oldDelegate.startIdx != startIdx || oldDelegate.endIdx != endIdx || oldDelegate.words != words;
}

/// Invisible-until-dragged text-selection layer for the PDF reader. Sits in
/// a [Stack] over the page image at the same size (see [book_reader_screen]'s
/// `_ReaderPage`, which wraps both in one `AspectRatio` so this overlay's
/// local coordinate space maps to PDF points with a single linear scale —
/// no `BoxFit` letterboxing math needed here).
///
/// Selection is a contiguous run in [words]' own order between the drag's
/// start and end word — not geometric rectangle intersection. Simple and
/// correct for normal reading order; known limitation for strict
/// multi-column layouts (accepted, not solved here).
class PdfTextSelectionOverlay extends StatefulWidget {
  final List<Map<String, dynamic>> words;
  final double pageWidth;
  final double pageHeight;
  final ValueChanged<String> onSelectionComplete;

  const PdfTextSelectionOverlay({
    super.key,
    required this.words,
    required this.pageWidth,
    required this.pageHeight,
    required this.onSelectionComplete,
  });

  @override
  State<PdfTextSelectionOverlay> createState() => _PdfTextSelectionOverlayState();
}

class _PdfTextSelectionOverlayState extends State<PdfTextSelectionOverlay> {
  int? _startIdx;
  int? _endIdx;

  /// Maps a local point (in this widget's own render box) to the nearest
  /// word index, in PDF-point space. Prefers a word whose vertical range
  /// contains the point (same line), falling back to nearest-by-distance so
  /// a drag starting in the margins still resolves to something sensible.
  int? _hitTest(Offset local, Size box) {
    if (widget.words.isEmpty) return null;
    final px = local.dx * widget.pageWidth / box.width;
    final py = local.dy * widget.pageHeight / box.height;

    int? best;
    double bestDist = double.infinity;
    for (var i = 0; i < widget.words.length; i++) {
      final w = widget.words[i];
      final x0 = (w['x0'] as num).toDouble();
      final y0 = (w['y0'] as num).toDouble();
      final x1 = (w['x1'] as num).toDouble();
      final y1 = (w['y1'] as num).toDouble();
      if (py >= y0 && py <= y1 && px >= x0 && px <= x1) return i;
      final cx = (x0 + x1) / 2;
      final cy = (y0 + y1) / 2;
      final dist = (px - cx) * (px - cx) + (py - cy) * (py - cy);
      if (dist < bestDist) {
        bestDist = dist;
        best = i;
      }
    }
    return best;
  }

  void _complete() {
    if (_startIdx == null || _endIdx == null) return;
    final lo = _startIdx! <= _endIdx! ? _startIdx! : _endIdx!;
    final hi = _startIdx! <= _endIdx! ? _endIdx! : _startIdx!;
    if (hi > lo) {
      final text = widget.words.sublist(lo, hi + 1).map((w) => w['text'] as String).join(' ');
      if (text.trim().isNotEmpty) widget.onSelectionComplete(text.trim());
    }
    setState(() {
      _startIdx = null;
      _endIdx = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final box = Size(constraints.maxWidth, constraints.maxHeight);
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: (d) => setState(() {
          _startIdx = _hitTest(d.localPosition, box);
          _endIdx = _startIdx;
        }),
        onPanUpdate: (d) => setState(() => _endIdx = _hitTest(d.localPosition, box) ?? _endIdx),
        onPanEnd: (_) => _complete(),
        onTap: () => setState(() {
          _startIdx = null;
          _endIdx = null;
        }),
        child: CustomPaint(
          painter: _WordHighlightPainter(
            words: widget.words,
            pageWidth: widget.pageWidth,
            pageHeight: widget.pageHeight,
            startIdx: _startIdx,
            endIdx: _endIdx,
          ),
          size: box,
        ),
      );
    });
  }
}
