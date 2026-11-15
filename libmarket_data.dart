import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

/// Un trade (impression) venant de l'exchange.
/// sellerAggressor == true  => le vendeur a frappe le bid => volume BID
/// sellerAggressor == false => l'acheteur a leve l'ask   => volume ASK
class Trade {
  final double price;
  final double qty;
  final bool sellerAggressor;
  final int timeMs;
  const Trade(this.price, this.qty, this.sellerAggressor, this.timeMs);
}

/// Flux temps reel + historique Binance.
class BinanceFeed {
  BinanceFeed(this.symbol);
  final String symbol;

  WebSocketChannel? _ws;
  final _ctrl = StreamController<Trade>.broadcast();
  Stream<Trade> get trades => _ctrl.stream;
  Timer? _reconnect;

  /// Derniers trades pour amorcer le graphique.
  Future<List<Trade>> fetchRecent({int limit = 1000}) async {
    final uri = Uri.parse(
        'https://api.binance.com/api/v3/aggTrades?symbol=${symbol.toUpperCase()}&limit=$limit');
    final r = await http.get(uri);
    final list = jsonDecode(r.body) as List<dynamic>;
    return list
        .map((e) => Trade(
              double.parse(e['p'] as String),
              double.parse(e['q'] as String),
              e['m'] as bool,
              e['T'] as int,
            ))
        .toList();
  }

  void connect() {
    _ws?.sink.close();
    _ws = WebSocketChannel.connect(Uri.parse(
        'wss://stream.binance.com:9443/ws/${symbol.toLowerCase()}@aggTrade'));
    _ws!.stream.listen((msg) {
      final m = jsonDecode(msg as String) as Map<String, dynamic>;
      _ctrl.add(Trade(
        double.parse(m['p'] as String),
        double.parse(m['q'] as String),
        m['m'] as bool,
        m['T'] as int,
      ));
    }, onDone: _retry, onError: (_) => _retry());
  }

  void _retry() {
    _reconnect?.cancel();
    _reconnect = Timer(const Duration(seconds: 3), connect);
  }

  void dispose() {
    _reconnect?.cancel();
    _ws?.sink.close();
    _ctrl.close();
  }
}