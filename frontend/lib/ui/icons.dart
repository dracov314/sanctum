// Per-system line-art icons — literal SVG path data from the design system
// handoff (iconPaths/systemIconKeys, Sanctum TTRPG App.dc.html ~L2313-2339),
// replacing the old ImageSlot "Cover" placeholder on Library system cards.
// A minimal SVG path parser (M/L/H/V/C/S/A/Z, abs+rel) renders these exactly
// rather than hand-approximating each glyph with a Material icon substitute.

import 'package:flutter/material.dart';
import 'dart:math' as math;

const kIconPaths = <String, String>{
  'die': 'M12 2 L19 9 L15 22 L9 22 L5 9 Z M12 2 L12 22 M5 9 L19 9',
  'sword': 'M12 2 V15 M8 5 H16 M9 18 H15 M10 21 H14',
  'skull': 'M12 2C7.6 2 5 5.2 5 9c0 2.8 1.4 4.7 3 6v3h2.5v-2.3h1v2.3h1v-2.3h1v2.3H17v-3c1.6-1.3 3-3.2 3-6 0-3.8-2.6-7-8-7Z M8.6 8.6h1.4v1.6H8.6z M14 8.6h1.4v1.6H14z',
  'moon': 'M15 3a9 9 0 1 0 0 18 7 7 0 0 1 0-18Z',
  'eye': 'M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12Z M12 9a3 3 0 1 0 0.01 0Z',
  'dragonwing': 'M3 20c4-1 6-4 6-8 3 2 4 5 3 9 3-2 5-6 4-11 3 1 5 4 5 8-6 3-13 4-18 2Z',
  'star': 'M12 2 L14 9 L21 9 L15.5 13.5 L17.5 21 L12 16.8 L6.5 21 L8.5 13.5 L3 9 L10 9 Z',
  'katana': 'M4 20 L17 7 M15 5 L19 9 M17 7 L19 5 M3 21 L5 19',
  'mecha': 'M7 4h10v6a5 5 0 0 1-10 0Z M9 8h.01 M15 8h.01 M5 2v2 M19 2v2 M10 16v4h4v-4',
  'gem': 'M4 9 L8 3 H16 L20 9 L12 21 Z M4 9 H20 M8 3 L12 9 L16 3 M12 9 L8.5 9 M12 9 L15.5 9',
  'compass': 'M12 2a10 10 0 1 0 0.01 0Z M12 6 L14 12 L12 18 L10 12Z',
  'chip': 'M7 7h10v10H7Z M9 3v4 M12 3v4 M15 3v4 M9 17v4 M12 17v4 M15 17v4 M3 9h4 M3 12h4 M3 15h4 M17 9h4 M17 12h4 M17 15h4',
  'rifle': 'M2 16 L14 16 L14 12 L22 12 M14 12 L14 8 L11 8 L11 12 M6 16 L6 20 M9 16 L9 20',
  'shield': 'M12 2 L20 5 V11c0 6-3.5 9.5-8 11-4.5-1.5-8-5-8-11V5Z',
  'portal': 'M12 12c0-2 2-2 2 0s-2 4-4 4-4-2-4-5 3-6 6-6 6 3 6 7-4 7-7 7',
  'dagger': 'M12 2 V13 M9 4 H15 M11 15 L12 21 L13 15Z',
};

const kSystemIconKeys = <String, String>{
  'Anima Beyond Fantasy': 'dragonwing', 'Black Crusade': 'skull', 'Chronicles of Darkness': 'moon',
  'Dark Heresy': 'skull', 'Deathwatch': 'shield', 'Dragon Age': 'dragonwing', 'Dungeons the Dragoning': 'die',
  'Exalted': 'star', 'Fantasy AGE': 'sword', 'Fuzion': 'die', 'Heroes Unlimited': 'star', 'Immortals': 'gem',
  'Kult': 'eye', 'Legend of the Five Rings': 'katana', 'Mekton': 'mecha', 'Obsidian': 'gem',
  'Old World of Darkness': 'moon', 'Only War': 'rifle', 'Rifts': 'portal', 'Rogue Trader': 'compass',
  'Shadowrun': 'chip', 'Shadowrun X - Latest': 'chip', 'Star Wars Saga Edition': 'star',
  'Vice and Violence': 'dagger', 'Warhammer 40k Shared Assets': 'skull',
};

String iconKeyForSystem(String systemName) => kSystemIconKeys[systemName] ?? 'die';

/// Outline SVG-path icon: 24x24 viewBox, stroke-only, matching the handoff's
/// `stroke="rgba(230,215,190,0.7)" strokeWidth="1.6"` line-art style.
class SystemIcon extends StatelessWidget {
  final String iconKey;
  final double size;
  final Color color;
  const SystemIcon(this.iconKey, {super.key, this.size = 28, this.color = const Color(0xB3E6D7BE)});

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(size, size),
        painter: _SvgPathPainter(kIconPaths[iconKey] ?? kIconPaths['die']!, color),
      );
}

class _SvgPathPainter extends CustomPainter {
  final String d;
  final Color color;
  _SvgPathPainter(this.d, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final path = parseSvgPath(d);
    final scale = size.width / 24.0; // viewBox is 0 0 24 24
    canvas.save();
    canvas.scale(scale, scale);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SvgPathPainter oldDelegate) => oldDelegate.d != d || oldDelegate.color != color;
}

/// Minimal SVG path-data parser — supports the commands actually used by the
/// handoff's icon set: M/m, L/l, H/h, V/v, C/c, S/s, A/a, Z/z.
Path parseSvgPath(String d) {
  final path = Path();
  final tokens = RegExp(r'[MmLlHhVvCcSsAaZz]|-?\d*\.?\d+(?:[eE][+-]?\d+)?')
      .allMatches(d)
      .map((m) => m.group(0)!)
      .toList();

  double curX = 0, curY = 0, startX = 0, startY = 0;
  double lastCtrlX = 0, lastCtrlY = 0;
  String lastCmd = '';
  int i = 0;
  double nextNum() => double.parse(tokens[i++]);
  bool isNum(String s) => RegExp(r'^-?\d').hasMatch(s);

  while (i < tokens.length) {
    final cmd = tokens[i++];
    switch (cmd) {
      case 'M':
      case 'm':
        final rel = cmd == 'm';
        var x = nextNum(), y = nextNum();
        if (rel) { x += curX; y += curY; }
        path.moveTo(x, y);
        curX = x; curY = y; startX = x; startY = y;
        lastCmd = rel ? 'l' : 'L';
        while (i < tokens.length && isNum(tokens[i])) {
          var x2 = nextNum(), y2 = nextNum();
          if (rel) { x2 += curX; y2 += curY; }
          path.lineTo(x2, y2);
          curX = x2; curY = y2;
        }
        break;
      case 'L':
      case 'l':
        final rel = cmd == 'l';
        while (i < tokens.length && isNum(tokens[i])) {
          var x = nextNum(), y = nextNum();
          if (rel) { x += curX; y += curY; }
          path.lineTo(x, y);
          curX = x; curY = y;
        }
        lastCmd = cmd;
        break;
      case 'H':
      case 'h':
        final rel = cmd == 'h';
        while (i < tokens.length && isNum(tokens[i])) {
          var x = nextNum();
          if (rel) x += curX;
          path.lineTo(x, curY);
          curX = x;
        }
        lastCmd = cmd;
        break;
      case 'V':
      case 'v':
        final rel = cmd == 'v';
        while (i < tokens.length && isNum(tokens[i])) {
          var y = nextNum();
          if (rel) y += curY;
          path.lineTo(curX, y);
          curY = y;
        }
        lastCmd = cmd;
        break;
      case 'C':
      case 'c':
        final rel = cmd == 'c';
        while (i < tokens.length && isNum(tokens[i])) {
          var x1 = nextNum(), y1 = nextNum(), x2 = nextNum(), y2 = nextNum(), x = nextNum(), y = nextNum();
          if (rel) { x1 += curX; y1 += curY; x2 += curX; y2 += curY; x += curX; y += curY; }
          path.cubicTo(x1, y1, x2, y2, x, y);
          curX = x; curY = y; lastCtrlX = x2; lastCtrlY = y2;
        }
        lastCmd = cmd;
        break;
      case 'S':
      case 's':
        final rel = cmd == 's';
        while (i < tokens.length && isNum(tokens[i])) {
          var x2 = nextNum(), y2 = nextNum(), x = nextNum(), y = nextNum();
          if (rel) { x2 += curX; y2 += curY; x += curX; y += curY; }
          final reflectX = (lastCmd == 'C' || lastCmd == 'c' || lastCmd == 'S' || lastCmd == 's')
              ? 2 * curX - lastCtrlX : curX;
          final reflectY = (lastCmd == 'C' || lastCmd == 'c' || lastCmd == 'S' || lastCmd == 's')
              ? 2 * curY - lastCtrlY : curY;
          path.cubicTo(reflectX, reflectY, x2, y2, x, y);
          curX = x; curY = y; lastCtrlX = x2; lastCtrlY = y2;
        }
        lastCmd = cmd;
        break;
      case 'A':
      case 'a':
        final rel = cmd == 'a';
        while (i < tokens.length && isNum(tokens[i])) {
          final rx = nextNum(), ry = nextNum(), rot = nextNum();
          final largeArc = nextNum() != 0, sweep = nextNum() != 0;
          var x = nextNum(), y = nextNum();
          if (rel) { x += curX; y += curY; }
          _arcTo(path, curX, curY, rx, ry, rot, largeArc, sweep, x, y);
          curX = x; curY = y;
        }
        lastCmd = cmd;
        break;
      case 'Z':
      case 'z':
        path.close();
        curX = startX; curY = startY;
        lastCmd = cmd;
        break;
    }
  }
  return path;
}

// SVG elliptical-arc-to-bezier conversion (endpoint -> center parameterization,
// per the SVG 1.1 spec appendix), approximated with cubic bezier segments.
void _arcTo(Path path, double x0, double y0, double rx, double ry, double rotDeg,
    bool largeArc, bool sweep, double x1, double y1) {
  if (rx == 0 || ry == 0) { path.lineTo(x1, y1); return; }
  final phi = rotDeg * math.pi / 180;
  final cosPhi = math.cos(phi), sinPhi = math.sin(phi);
  final dx2 = (x0 - x1) / 2, dy2 = (y0 - y1) / 2;
  final x1p = cosPhi * dx2 + sinPhi * dy2;
  final y1p = -sinPhi * dx2 + cosPhi * dy2;

  var rxAbs = rx.abs(), ryAbs = ry.abs();
  final lambda = (x1p * x1p) / (rxAbs * rxAbs) + (y1p * y1p) / (ryAbs * ryAbs);
  if (lambda > 1) {
    final s = math.sqrt(lambda);
    rxAbs *= s; ryAbs *= s;
  }

  final sign = largeArc != sweep ? 1.0 : -1.0;
  final num = rxAbs * rxAbs * ryAbs * ryAbs - rxAbs * rxAbs * y1p * y1p - ryAbs * ryAbs * x1p * x1p;
  final den = rxAbs * rxAbs * y1p * y1p + ryAbs * ryAbs * x1p * x1p;
  final coef = sign * math.sqrt(math.max(0, num / den));
  final cxp = coef * (rxAbs * y1p / ryAbs);
  final cyp = coef * -(ryAbs * x1p / rxAbs);

  final cx = cosPhi * cxp - sinPhi * cyp + (x0 + x1) / 2;
  final cy = sinPhi * cxp + cosPhi * cyp + (y0 + y1) / 2;

  double angle(double ux, double uy, double vx, double vy) {
    final dot = ux * vx + uy * vy;
    final len = math.sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy));
    var a = math.acos((dot / len).clamp(-1.0, 1.0));
    if (ux * vy - uy * vx < 0) a = -a;
    return a;
  }

  final theta1 = angle(1, 0, (x1p - cxp) / rxAbs, (y1p - cyp) / ryAbs);
  var dTheta = angle((x1p - cxp) / rxAbs, (y1p - cyp) / ryAbs, (-x1p - cxp) / rxAbs, (-y1p - cyp) / ryAbs);
  if (!sweep && dTheta > 0) dTheta -= 2 * math.pi;
  if (sweep && dTheta < 0) dTheta += 2 * math.pi;

  // Split into <= 90-degree cubic bezier segments.
  final segments = (dTheta.abs() / (math.pi / 2)).ceil().clamp(1, 8);
  final delta = dTheta / segments;
  final t = 4 / 3 * math.tan(delta / 4);
  var thetaI = theta1;
  // Point on ellipse at parameter th (rotated by phi) and its derivative.
  double ellipseX(double th) => cx + rxAbs * math.cos(th) * cosPhi - ryAbs * math.sin(th) * sinPhi;
  double ellipseY(double th) => cy + rxAbs * math.cos(th) * sinPhi + ryAbs * math.sin(th) * cosPhi;
  double derivX(double th) => -rxAbs * math.sin(th) * cosPhi - ryAbs * math.cos(th) * sinPhi;
  double derivY(double th) => -rxAbs * math.sin(th) * sinPhi + ryAbs * math.cos(th) * cosPhi;

  for (var i = 0; i < segments; i++) {
    final thetaNext = thetaI + delta;
    final e1x = ellipseX(thetaI), e1y = ellipseY(thetaI);
    final e2x = ellipseX(thetaNext), e2y = ellipseY(thetaNext);
    final c1x = e1x + t * derivX(thetaI), c1y = e1y + t * derivY(thetaI);
    final c2x = e2x - t * derivX(thetaNext), c2y = e2y - t * derivY(thetaNext);
    path.cubicTo(c1x, c1y, c2x, c2y, e2x, e2y);
    thetaI = thetaNext;
  }
}
