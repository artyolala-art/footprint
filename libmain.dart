import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'market_data.dart';
import 'footprint_engine.dart';
import 'footprint_painter.dart';

void main() => runApp(const FootprintApp());

class FootprintApp extends StatelessWidget {
  const FootprintApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Footprint Chart Pro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B0E13),
      ),
      home: const ChartPage(),
    );
  }
}

class ChartPage extends StatefulWidget {
  const ChartPage({super.key});
  @override
  State<ChartPage> createState() => _ChartPageState();
}

class _ChartPageState extends State<ChartPage> {
  static const Map<String, double> kDefaultTick = {
    'BTCUSDT': 10, 'ETHUSDT': 1, 'SOLUSDT': 0.1, 'BNBUSDT': 0.1,
    'XRPUSDT': 0.001, 'DOGEUSDT': 0.0001,
  };
  static const Map<String, int> kTimeframes = {
    '1m': 60, '5m': 300, '15m': 900, '1h': 3600,
  };

  String _symbol = 'BTCUSDT';
  double _tick = 10;
  int _tfSec = 60;
  FpStyle _style = FpStyle.classic;

  BinanceFeed? _feed;
  FootprintEngine _engine = FootprintEngine(tickSize: 10, tfSeconds: 60);
  final List<Trade> _buffer = [];
  StreamSubscription<Trade>? _sub;
  Timer? _repaintTimer;
  bool _dirty = false;
  bool _loading = true;

  double _camShift = 0;   // barres depuis la droite (comme g_cam_right_shift)
  double _barWidth = 46;  // comme g_cam_spacing
  double _priceMin = 0, _priceMax = 0;
  double _gestBw = 46;

  @override
  void initState() {
    super.initState();
    _start();
    _repaintTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_dirty && mounted) setState(() => _dirty = false);
    });
  }

  @override
  void dispose() {
    _repaintTimer?.cancel();
    _sub?.cancel();
    _feed?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    await _sub?.cancel();
    _feed?.dispose();
    _feed = BinanceFeed(_symbol);
    _buffer.clear();
    _rebuild();
    setState(() => _loading = true);
    try {
      final hist = await _feed!.fetchRecent();
      _buffer.addAll(hist);
      _rebuild();
    } catch (_) {}
    _loading = false;
    _feed!.connect();
    _sub = _feed!.trades.listen((t) {
      _buffer.add(t);
      if (_buffer.length > 50000) _buffer.removeRange(0, 25000);
      _engine.addTrade(t);
      _dirty = true;
    });
    if (mounted) setState(() {});
  }

  void _rebuild() {
    _engine = FootprintEngine(tickSize: _tick, tfSeconds: _tfSec);
    _engine.addAll(_buffer);
  }

  void _changeSymbol(String s) {
    final sym = s.toUpperCase().trim();
    if (sym.isEmpty || sym == _symbol) return;
    setState(() {
      _symbol = sym;
      _tick = kDefaultTick[sym] ?? _tick;
      _camShift = 0;
      _priceMin = 0;
      _priceMax = 0;
    });
    _start();
  }

  // Auto-echelle verticale (equivalent de g_auto_y)
  void _autoScale(double chartW) {
    final n = _engine.bars.length;
    if (n == 0) return;
    double lo = double.infinity, hi = -double.infinity;
    for (var i = 0; i < n; i++) {
      final x = chartW - ((n - 1 - i) + _camShift) * _barWidth - _barWidth / 2;
      if (x + _barWidth / 2 < 0 || x - _barWidth / 2 > chartW) continue;
      final b = _engine.bars[i];
      if (b.levels.isEmpty) continue;
      if (b.low < lo) lo = b.low;
      if (b.high > hi) hi = b.high;
    }
    if (lo == double.infinity || hi <= lo) return;
    final pad = (hi - lo) * 0.08 + _tick;
    lo -= pad; hi += pad;
    if (_priceMax <= _priceMin) {
      _priceMin = lo; _priceMax = hi;
    } else {
      _priceMin += (lo - _priceMin) * 0.2;
      _priceMax += (hi - _priceMax) * 0.2;
    }
  }

  void _askSymbol() {
    final ctrl = TextEditingController(text: _symbol);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Symbole Binance'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'ex : BTCUSDT'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(
            onPressed: () { Navigator.pop(ctx); _changeSymbol(ctrl.text); },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        title: TextButton.icon(
          onPressed: _askSymbol,
          icon: const Icon(Icons.currency_bitcoin, color: Colors.amber),
          label: Text(_symbol,
              style: const TextStyle(color: Colors.white, fontSize: 18)),
        ),
        actions: [
          IconButton(tooltip: 'Zoom +', icon: const Icon(Icons.zoom_in),
              onPressed: () => setState(() => _barWidth = (_barWidth * 1.25).clamp(4.0, 240.0))),
          IconButton(tooltip: 'Zoom -', icon: const Icon(Icons.zoom_out),
              onPressed: () => setState(() => _barWidth = (_barWidth / 1.25).clamp(4.0, 240.0))),
          IconButton(tooltip: 'Retour temps reel', icon: const Icon(Icons.skip_next),
              onPressed: () => setState(() => _camShift = 0)),
        ],
      ),
      body: Column(
        children: [
          _buildToolbar(),
          Expanded(
            child: LayoutBuilder(builder: (context, c) {
              final chartW = c.maxWidth - FootprintPainter.axisW;
              _autoScale(chartW);
              return GestureDetector(
                onScaleStart: (d) => _gestBw = _barWidth,
                onScaleUpdate: (d) {
                  setState(() {
                    if ((d.scale - 1).abs() > 0.001) {
                      _barWidth = (_gestBw * d.scale).clamp(4.0, 240.0);
                    }
                    final maxShift = math.max(0, _engine.bars.length - 3).toDouble();
                    _camShift = (_camShift - d.focalPointDelta.dx / _barWidth)
                        .clamp(0.0, maxShift);
                  });
                },
                onDoubleTap: () => setState(() => _camShift = 0),
                child: CustomPaint(
                  size: Size(c.maxWidth, c.maxHeight),
                  painter: FootprintPainter(
                    bars: _engine.bars,
                    tickSize: _tick,
                    style: _style,
                    camShift: _camShift,
                    barWidth: _barWidth,
                    priceMax: _priceMax,
                    priceMin: _priceMin,
                  ),
                  child: _engine.bars.isEmpty
                      ? Center(
                          child: _loading
                              ? const CircularProgressIndicator()
                              : const Text('En attente de donnees...'))
                      : null,
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    return Container(
      color: const Color(0xFF10141C),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            const Text('Style :', style: TextStyle(fontSize: 12)),
            const SizedBox(width: 6),
            DropdownButton<FpStyle>(
              value: _style, isDense: true,
              dropdownColor: const Color(0xFF10141C),
              items: kStyleNames.entries
                  .map((e) => DropdownMenuItem(
                      value: e.key,
                      child: Text(e.value, style: const TextStyle(fontSize: 13))))
                  .toList(),
              onChanged: (v) => setState(() => _style = v!),
            ),
            const SizedBox(width: 12),
            const Text('TF :', style: TextStyle(fontSize: 12)),
            const SizedBox(width: 6),
            DropdownButton<int>(
              value: _tfSec, isDense: true,
              dropdownColor: const Color(0xFF10141C),
              items: kTimeframes.entries
                  .map((e) => DropdownMenuItem(
                      value: e.value,
                      child: Text(e.key, style: const TextStyle(fontSize: 13))))
                  .toList(),
              onChanged: (v) => setState(() {
                _tfSec = v!; _rebuild();
                _camShift = 0; _priceMin = 0; _priceMax = 0;
              }),
            ),
            const SizedBox(width: 12),
            const Text('Pas de prix :', style: TextStyle(fontSize: 12)),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.remove, size: 16),
              onPressed: () => setState(() { _tick = math.max(_tick / 2, 1e-6); _rebuild(); }),
            ),
            Text(_tick >= 1 ? _tick.toStringAsFixed(0) : _tick.toString(),
                style: const TextStyle(fontSize: 12)),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add, size: 16),
              onPressed: () => setState(() { _tick *= 2; _rebuild(); }),
            ),
          ],
        ),
      ),
    );
  }
}