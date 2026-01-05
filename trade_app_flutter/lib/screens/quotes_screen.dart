import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math';
import 'dart:convert'; // Added for jsonDecode
import 'package:web_socket_channel/web_socket_channel.dart';

class QuotesScreen extends StatefulWidget {
  final VoidCallback? onMenuTap;
  const QuotesScreen({super.key, this.onMenuTap});

  @override
  State<QuotesScreen> createState() => _QuotesScreenState();
}

class _QuotesScreenState extends State<QuotesScreen> with AutomaticKeepAliveClientMixin {
  // Single WebSocket channel for all symbols
  WebSocketChannel? _channel;
  
  // Keep the state alive
  @override
  bool get wantKeepAlive => true;
  
  // Store current price data
  final List<Map<String, dynamic>> _quotes = [
    {'symbol': 'EURUSD', 'bid': 0.0, 'ask': 0.0, 'change': 0.0},
    {'symbol': 'GBPUSD', 'bid': 0.0, 'ask': 0.0, 'change': 0.0},
    {'symbol': 'USDJPY', 'bid': 0.0, 'ask': 0.0, 'change': 0.0},
    {'symbol': 'XAUUSD', 'bid': 0.0, 'ask': 0.0, 'change': 0.0},
    {'symbol': 'BTCUSD', 'bid': 0.0, 'ask': 0.0, 'change': 0.0},
  ];

  @override
  void initState() {
    super.initState();
    _connectWebSocket();
  }

  void _connectWebSocket() {
    // Single connection to the main stream
    const String url = 'ws://192.168.1.41:8000/ws/quotes'; 
    try {
      _channel = WebSocketChannel.connect(Uri.parse(url));
      print("Connecting to $url");

      _channel!.stream.listen((message) {
        final data = jsonDecode(message);
        // data format: {symbol: "EURUSD", bid: 1.05, ask: 1.06 ...}
        if (mounted) {
          setState(() {
            _updateQuote(data['symbol'], data['bid'], data['ask']);
          });
        }
      }, onError: (error) {
        print("WS Error: $error");
      }, onDone: () {
        print("WS Closed. Reconnecting in 5s...");
        Future.delayed(const Duration(seconds: 5), _connectWebSocket);
      });
    } catch (e) {
      print("Connection failed: $e");
    }
  }

  void _updateQuote(String symbol, double newBid, double newAsk) {
    // Find symbol in our list (ignoring suffix like 'm' if logic handled in backend, 
    // but here we expect backend to send clean 'symbol' name or we match loosely)
    final index = _quotes.indexWhere((q) => q['symbol'] == symbol);
    
    if (index != -1) {
      final oldBid = _quotes[index]['bid'] as double;
      
      // Flash logic
      int flashState = 0; 
      if (oldBid != 0) { // Only flash if not first update
        if (newBid > oldBid) flashState = 1;
        else if (newBid < oldBid) flashState = -1;
      }

      _quotes[index]['bid'] = newBid;
      _quotes[index]['ask'] = newAsk;
      _quotes[index]['change'] = flashState;
      
      // Reset flash effect after 300ms
      if (flashState != 0) {
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) {
            setState(() {
               _quotes[index]['change'] = 0;
            });
          }
        });
      }
    }
  }

  @override
  void dispose() {
    _channel?.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => widget.onMenuTap?.call(),
        ),
        title: const Text("Quotes", style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
      ),
      body: ListView.separated(
        itemCount: _quotes.length,
        separatorBuilder: (ctx, i) => const Divider(height: 1, color: Colors.white10),
        itemBuilder: (context, index) {
          final s = _quotes[index];
          int digits = s['symbol'].contains('JPY') || s['symbol'] == 'XAUUSD' ? 2 : 5;
          if (s['symbol'] == 'BTCUSD') digits = 1;

          // Calculate visual state
          double bid = s['bid'];
          double prevBid = s['bid']; // Initial state, logic handles change via 'change' field now
          
          Color flashColor = Colors.white;
          if (s['change'] == 1) flashColor = Colors.blueAccent;
          else if (s['change'] == -1) flashColor = Colors.redAccent;

          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12.0, horizontal: 16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Symbol Name & Time
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s['symbol'], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                    const SizedBox(height: 4),
                    Text("10:23:05", style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                  ],
                ),
                
                // Prices (Bid / Ask)
                Row(
                  children: [
                    _PriceBox(price: s['bid'], label: "Bid", color: flashColor, digits: digits),
                    const SizedBox(width: 15),
                    _PriceBox(price: s['ask'], label: "Ask", color: flashColor, digits: digits),
                  ],
                )
              ],
            ),
          );
        },
      ),
    );
  }
}

class _PriceBox extends StatelessWidget {
  final double price;
  final String label;
  final Color color;
  final int digits;

  const _PriceBox({required this.price, required this.label, required this.color, required this.digits});

  @override
  Widget build(BuildContext context) {
    // Format price: Big numbers for the last two digits
    String priceStr = price.toStringAsFixed(digits);
    String bigPart = "";
    String smallPart = "";
    
    if (priceStr.length > 2) {
       smallPart = priceStr.substring(0, priceStr.length - 2);
       bigPart = priceStr.substring(priceStr.length - 2);
    } else {
       bigPart = priceStr;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(smallPart, style: TextStyle(color: color, fontSize: 16)),
            Text(bigPart, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 24)),
          ],
        ),
        Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 10)),
      ],
    );
  }
}

