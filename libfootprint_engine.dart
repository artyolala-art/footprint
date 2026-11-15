import 'market_data.dart';

/// Un niveau de prix dans une bougie (equivalent SFpLevel).
class FootLevel {
  double bid = 0;
  double ask = 0;
  double get delta => ask - bid;
  double get vol => bid + ask;
}

/// Une bougie footprint (equivalent SFpBar).
class FootBar {
  FootBar(this.tStart);
  final int tStart;
  double open = 0, high = 0, low = double.infinity, close = 0;
  final Map<int, FootLevel> levels = {}; // cle = index de tick

  double get delta => levels.values.fold(0.0, (s, l) => s + l.delta);
  double get vol => levels.values.fold(0.0, (s, l) => s + l.vol);
  bool get isUp => close >= open;

  int get pocIndex {
    int best = 0;
    double bv = -1;
    levels.forEach((i, l) {
      if (l.vol > bv) { bv = l.vol; best = i; }
    });
    return best;
  }
}

/// Moteur : ticks -> bougies footprint (equivalent GetBar/UpdateLive).
class FootprintEngine {
  FootprintEngine({required this.tickSize, required this.tfSeconds, this.maxBars = 300});
  final double tickSize;
  final int tfSeconds;
  final int maxBars;
  final List<FootBar> bars = [];

  void addTrade(Trade t) {
    final start = (t.timeMs ~/ (tfSeconds * 1000)) * (tfSeconds * 1000);
    if (bars.isEmpty || bars.last.tStart != start) {
      bars.add(FootBar(start));
      if (bars.length > maxBars) bars.removeAt(0);
    }
    final b = bars.last;
    if (b.levels.isEmpty) b.open = t.price;
    b.close = t.price;
    if (t.price > b.high) b.high = t.price;
    if (t.price < b.low) b.low = t.price;
    final idx = (t.price / tickSize).round();
    final lvl = b.levels.putIfAbsent(idx, () => FootLevel());
    if (t.sellerAggressor) {
      lvl.bid += t.qty;
    } else {
      lvl.ask += t.qty;
    }
  }

  void addAll(Iterable<Trade> ts) {
    for (final t in ts) { addTrade(t); }
  }
}