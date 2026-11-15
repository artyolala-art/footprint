import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'footprint_engine.dart';

/// Styles disponibles (sous-ensemble des 18 styles de l'indicateur MT5).
enum FpStyle { classic, deltaCells, volProfile, heatmap, ladder }

const Map<FpStyle, String> kStyleNames = {
  FpStyle.classic:    'Bid x Ask (classique)',
  FpStyle.deltaCells: 'Delta Cells',
  FpStyle.volProfile: 'Volume Profile',
  FpStyle.heatmap:    'Heatmap',
  FpStyle.ladder:     'Ladder (Bid|Ask)',
};

class FootprintPainter extends CustomPainter {
  FootprintPainter({
    required this.bars,
    required this.tickSize,
    required this.style,
    required this.camShift,   // decalage en barres depuis la droite
    required this.barWidth,   // largeur d'une barre en px
    required this.priceMax,
    required this.priceMin,
    this.imbalanceRatio = 3.0,
    this.imbalanceMin = 0,
  });

  final List<FootBar> bars;
  final double tickSize;
  final FpStyle style;
  final double camShift;
  final double barWidth;
  final double priceMax;
  final double priceMin;
  final double imbalanceRatio;
  final double imbalanceMin;

  static const double axisW = 72;   // largeur echelle des prix
  static const double timeH = 26;   // hauteur axe du temps
  static const double minRowPx = 7; // seuil "heat" (comme InpFontMinPx)

  static const Color bg      = Color(0xFF10141C);
  static const Color gridCol = Color(0xFF1E2530);
  static const Color bull    = Color(0xFF16A085);
  static const Color bear    = Color(0xFFCD3333);
  static const Color txt     = Color(0xFFDDE3EE);
  static const Color gold    = Color(0xFFFFD700);

  int get _decimals {
    if (tickSize >= 1) return 0;
    return (-(math.log(tickSize) / math.ln10)).ceil().clamp(0, 8).toInt();
  }

  String fmtVol(double v) {
    if (v >= 1e6) return '${(v / 1e6).toStringAsFixed(1)}M';
    if (v >= 1e3) return '${(v / 1e3).toStringAsFixed(1)}K';
    return v.toStringAsFixed(v < 10 ? 1 : 0);
  }

  String fmtDelta(double d) => '${d >= 0 ? "+" : "-"}${fmtVol(d.abs())}';

  double _barX(int i, double chartW) =>
      chartW - ((bars.length - 1 - i) + camShift) * barWidth - barWidth / 2;

  double _py(double price, double chartH) =>
      (priceMax - price) / (priceMax - priceMin) * chartH;

  void _text(Canvas c, String s, Offset center, double size, Color color,
      {bool bold = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, center - Offset(tp.width / 2, tp.height / 2));
  }

  Color _intensity(Color base, double k) => Color.lerp(
      base.withOpacity(0.18), base.withOpacity(0.85), k.clamp(0.0, 1.0))!;

  double _niceStep(double raw) {
    final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    final m = raw / mag;
    if (m < 1.5) return mag;
    if (m < 3.5) return 2 * mag;
    if (m < 7.5) return 5 * mag;
    return 10 * mag;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final chartW = size.width - axisW;
    final chartH = size.height - timeH;
    canvas.drawRect(Offset.zero & size, Paint()..color = bg);
    if (priceMax > priceMin) _drawGrid(canvas, chartW, chartH);
    if (bars.isEmpty || priceMax <= priceMin) return;

    final nTicks = ((priceMax - priceMin) / tickSize).clamp(1.0, double.infinity);
    final rowPx = chartH / nTicks;
    final bool heat = rowPx < minRowPx || barWidth < 26;
    final int bucket = heat ? math.max(1, (minRowPx / math.max(rowPx, 0.01)).ceil()) : 1;

    // Normalisation sur les barres visibles (comme m0)
    double maxVol = 1, maxAbsDelta = 1;
    for (var i = 0; i < bars.length; i++) {
      final x = _barX(i, chartW);
      if (x + barWidth / 2 < 0 || x - barWidth / 2 > chartW) continue;
      for (final l in bars[i].levels.values) {
        if (l.vol > maxVol) maxVol = l.vol;
        if (l.delta.abs() > maxAbsDelta) maxAbsDelta = l.delta.abs();
      }
    }

    for (var i = 0; i < bars.length; i++) {
      final x = _barX(i, chartW);
      if (x + barWidth / 2 < 0 || x - barWidth / 2 > chartW) continue;
      _drawBar(canvas, bars[i], x, chartH, bucket, rowPx, heat, maxVol, maxAbsDelta);
    }

    _drawLastPrice(canvas, chartW, chartH);
    _drawAxisLabels(canvas, chartW, chartH);
    _drawTimeAxis(canvas, chartW, size.height);
  }

  // ===================== EQUIVALENT DrawBar() =====================
  void _drawBar(Canvas c, FootBar b, double xc, double chartH, int bucket,
      double rowPx, bool heat, double maxVol, double maxAbsDelta) {
    if (b.levels.isEmpty) return;
    final cellW = barWidth * 0.92;
    final left = xc - cellW / 2;
    final fontSize = math.min(cellW / 5.2, bucket * rowPx * 0.62).clamp(6.0, 14.0);
    final imbMin = math.max(imbalanceMin, maxVol * 0.02);

    // Regroupement en seaux (bucketing, comme la version MT5)
    final idxs = b.levels.keys.toList()..sort();
    final bi = <int>[]; final bb = <double>[]; final ba = <double>[];
    var k = 0;
    while (k < idxs.length) {
      final base = (idxs[k] ~/ bucket) * bucket;
      double bid = 0, ask = 0;
      var j = k;
      while (j < idxs.length && (idxs[j] ~/ bucket) * bucket == base) {
        bid += b.levels[idxs[j]]!.bid;
        ask += b.levels[idxs[j]]!.ask;
        j++;
      }
      bi.add(base); bb.add(bid); ba.add(ask);
      k = j;
    }

    final pocBase = (b.pocIndex ~/ bucket) * bucket;

    for (var m = 0; m < bi.length; m++) {
      final priceC = (bi[m] + bucket / 2) * tickSize;
      final y = _py(priceC, chartH);
      final cellH = math.max(2.0, bucket * rowPx - 0.5);
      final rect = Rect.fromLTWH(left, y - cellH / 2, cellW, cellH);
      final bid = bb[m], ask = ba[m];
      final vol = bid + ask, delta = ask - bid;
      final kv = (vol / maxVol).clamp(0.0, 1.0);
      final kd = (delta.abs() / maxAbsDelta).clamp(0.0, 1.0);
      final dir = delta >= 0 ? bull : bear;

      switch (style) {
        case FpStyle.classic:
          c.drawRect(rect, Paint()..color = _intensity(dir, kv).withOpacity(0.25));
          if (!heat) _text(c, '${fmtVol(bid)} x ${fmtVol(ask)}', rect.center, fontSize, txt);
          break;
        case FpStyle.deltaCells:
          c.drawRect(rect, Paint()..color = _intensity(dir, kd));
          if (!heat) _text(c, fmtDelta(delta), rect.center, fontSize, txt, bold: true);
          break;
        case FpStyle.volProfile:
          c.drawRect(Rect.fromLTWH(left, rect.top, cellW * kv, cellH),
              Paint()..color = dir.withOpacity(0.45));
          if (!heat) _text(c, fmtVol(vol), rect.center, fontSize, txt);
          break;
        case FpStyle.heatmap:
          c.drawRect(rect, Paint()..color = _intensity(dir, kv));
          if (!heat && cellW > 52) _text(c, fmtVol(vol), rect.center, fontSize, txt);
          break;
        case FpStyle.ladder:
          c.drawRect(rect, Paint()..color = dir.withOpacity(0.12));
          c.drawLine(Offset(xc, rect.top), Offset(xc, rect.bottom),
              Paint()..color = gridCol);
          if (!heat) {
            _text(c, fmtVol(bid), Offset(left + cellW * 0.25, y), fontSize, txt);
            _text(c, fmtVol(ask), Offset(left + cellW * 0.75, y), fontSize, txt);
          }
          break;
      }

      if (!heat) {
        c.drawRect(rect, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5
          ..color = gridCol);
      }

      // POC (cadre dore)
      if (bi[m] == pocBase) {
        c.drawRect(rect, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = gold);
      }

      // Imbalances diagonaux (marqueurs lateraux, comme bimb/simb)
      if (!heat) {
        if (m > 0 && ba[m] >= imbMin && ba[m] >= bb[m - 1] * imbalanceRatio) {
          c.drawRect(Rect.fromLTWH(rect.right - 3, rect.top, 3, cellH),
              Paint()..color = const Color(0xFF00FFAA));
        }
        if (m < bi.length - 1 && bb[m] >= imbMin && bb[m] >= ba[m + 1] * imbalanceRatio) {
          c.drawRect(Rect.fromLTWH(rect.left, rect.top, 3, cellH),
              Paint()..color = const Color(0xFFFF5577));
        }
      }
    }
  }

  void _drawGrid(Canvas c, double w, double h) {
    final step = _niceStep((priceMax - priceMin) / 8);
    final p = Paint()..color = gridCol..strokeWidth = 1;
    double v = (priceMin / step).ceil() * step;
    for (; v <= priceMax; v += step) {
      final y = _py(v, h);
      c.drawLine(Offset(0, y), Offset(w, y), p);
    }
  }

  void _drawAxisLabels(Canvas c, double w, double h) {
    final step = _niceStep((priceMax - priceMin) / 8);
    double v = (priceMin / step).ceil() * step;
    for (; v <= priceMax; v += step) {
      _text(c, v.toStringAsFixed(_decimals),
          Offset(w + axisW / 2, _py(v, h)), 10, txt);
    }
    c.drawLine(Offset(w, 0), Offset(w, h + timeH), Paint()..color = gridCol);
  }

  void _drawLastPrice(Canvas c, double w, double h) {
    if (bars.isEmpty || bars.last.levels.isEmpty) return;
    final b = bars.last;
    final y = _py(b.close, h);
    if (y < 0 || y > h) return;
    final col = b.isUp ? bull : bear;
    final p = Paint()..color = col.withOpacity(0.6)..strokeWidth = 1;
    double x = 0;
    while (x < w) {
      c.drawLine(Offset(x, y), Offset(math.min(x + 6, w), y), p);
      x += 12;
    }
    final tp = TextPainter(
      text: TextSpan(
        text: b.close.toStringAsFixed(_decimals),
        style: const TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final r = Rect.fromCenter(
        center: Offset(w + axisW / 2, y), width: axisW - 6, height: tp.height + 6);
    c.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(3)), Paint()..color = col);
    tp.paint(c, Offset(r.center.dx - tp.width / 2, r.center.dy - tp.height / 2));
  }

  void _drawTimeAxis(Canvas c, double w, double totalH) {
    c.drawRect(Rect.fromLTWH(0, totalH - timeH, w + axisW, timeH),
        Paint()..color = const Color(0xFF0B0E13));
    final step = math.max(1, (90 / barWidth).ceil());
    for (var i = 0; i < bars.length; i++) {
      final x = _barX(i, w);
      if (x < -barWidth || x > w + barWidth) continue;
      if ((bars.length - 1 - i + camShift.round()) % step != 0) continue;
      final t = DateTime.fromMillisecondsSinceEpoch(bars[i].tStart);
      final lbl = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
      _text(c, lbl, Offset(x, totalH - timeH / 2), 10, txt.withOpacity(0.7));
    }
  }

  @override
  bool shouldRepaint(covariant FootprintPainter old) => true;
}