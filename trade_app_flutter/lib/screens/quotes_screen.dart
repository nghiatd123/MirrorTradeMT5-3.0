import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math';
import 'dart:convert'; // Added for jsonDecode
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import '../api_config.dart';

class QuotesScreen extends StatefulWidget {
  final VoidCallback? onMenuTap;
  const QuotesScreen({super.key, this.onMenuTap});

  @override
  State<QuotesScreen> createState() => _QuotesScreenState();
}

class _QuotesScreenState extends State<QuotesScreen> with AutomaticKeepAliveClientMixin {
  // Single WebSocket channel for all symbols
  // Single WebSocket channel for all symbols
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  
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

  String _connectionStatus = "Disconnected";

  @override
  void initState() {
    super.initState();
    _connectWebSocket();
  }

  void _connectWebSocket() {
    if (!mounted) return;

    // Cleanup previous connection
    _subscription?.cancel();
    _channel?.sink.close();
    _subscription = null;
    _channel = null;

    setState(() => _connectionStatus = "Connecting...");
    
    // Single connection to the main stream
    const String url = '${ApiConfig.wsUrl}/ws/quotes'; 
    try {
      print("Connecting to $url");
      _channel = WebSocketChannel.connect(Uri.parse(url));

      _subscription = _channel!.stream.listen((message) {
        if (_connectionStatus != "Connected") {
             if (mounted) setState(() => _connectionStatus = "Connected");
        }
        try {
          final data = jsonDecode(message);
          if (mounted) {
            setState(() {
              _updateQuote(data['symbol'], data['bid'], data['ask']);
            });
          }
        } catch (e) {
          // print("WS Parse Error: $e");
        }
      }, onError: (error) {
        print("WS Error: $error");
        if (mounted) setState(() => _connectionStatus = "Error: Network issue");
        // Don't retry inside Error if Done also fires. Usually Done fires after Error.
      }, onDone: () {
        print("WS Closed. Reconnecting in 5s...");
        if (mounted) {
           setState(() => _connectionStatus = "Closed (Retry in 5s)");
           Future.delayed(const Duration(seconds: 5), _connectWebSocket);
        }
      });
    } catch (e) {
      print("Connection failed: $e");
      if (mounted) {
          setState(() => _connectionStatus = "Exception: Failed to connect");
          // Retry even on initial exception
          Future.delayed(const Duration(seconds: 5), _connectWebSocket);
      }
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
        title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
                const Text("Quotes", style: TextStyle(fontWeight: FontWeight.bold)),
                Text(_connectionStatus, style: TextStyle(
                    fontSize: 12, 
                    color: _connectionStatus == "Connected" ? Colors.greenAccent : Colors.redAccent
                )),
            ]
        ),
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

