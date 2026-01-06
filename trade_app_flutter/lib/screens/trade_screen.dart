import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:convert';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'login_screen.dart';
import '../widgets/side_menu.dart';
import '../api_config.dart';

class TradeScreen extends StatefulWidget {
  final Function(String)? onSymbolSelected;
  final VoidCallback? onMenuTap;
  final String login;
  const TradeScreen({super.key, this.onSymbolSelected, this.onMenuTap, required this.login});

  @override
  State<TradeScreen> createState() => _TradeScreenState();
}

class _TradeScreenState extends State<TradeScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  WebSocketChannel? _channel;
  Map<String, dynamic>? _accountInfo;
  List<dynamic> _positions = [];
  List<dynamic> _orders = [];
  bool _isConnected = false;

  final NumberFormat _currencyFmt = NumberFormat("#,##0.00", "en_US");

  @override
  void initState() {
    super.initState();
    _connectWebSocket();
  }
  
  // ... dispose & connectWebSocket & closePosition & bulkClose ...
    @override
  void dispose() {
    _channel?.sink.close();
    super.dispose();
  }

  void _connectWebSocket() {
    _channel = WebSocketChannel.connect(Uri.parse('${ApiConfig.wsUrl}/ws/positions'));
    _channel!.stream.listen((message) {
      try {
        final rawData = jsonDecode(message);
        // Backend sends { "123": { "account": ..., "positions": ... }, "456": ... }
        final String uid = widget.login.toString();
        
        if (rawData.containsKey(uid)) {
           final data = rawData[uid];
           if (mounted) {
              setState(() {
                if (data.containsKey('account')) {
                  _accountInfo = data['account'];
                }
                if (data.containsKey('positions')) {
                  final allItems = data['positions'] as List;
                  _positions = allItems.where((i) => i['status'] == 'OPEN').toList();
                  _orders = allItems.where((i) => i['status'] == 'PENDING').toList();
                }
                _isConnected = true;
              });
           }
        }
      } catch (e) {
        print("Trade WS Error: $e");
      }
    }, onError: (e) {
      print("Trade WS Connection Error: $e");
      setState(() => _isConnected = false);
      Future.delayed(const Duration(seconds: 3), _connectWebSocket);
    }, onDone: () {
      print("Trade WS Disconnected");
      setState(() => _isConnected = false);
      Future.delayed(const Duration(seconds: 3), _connectWebSocket);
    });
  }

  Future<void> _bulkClose(String symbol, String status) async {
    List<dynamic> targets = [];
    if (status == 'OPEN') {
      targets = _positions.where((p) => p['symbol'] == symbol).toList();
    } else {
      targets = _orders.where((p) => p['symbol'] == symbol).toList();
    }

    if (targets.isEmpty) return;

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text("Bulk Closing ${targets.length} ${status == 'OPEN' ? 'Positions' : 'Orders'} for $symbol..."),
      backgroundColor: Colors.blue,
      duration: const Duration(seconds: 1),
    ));

    final futures = targets.map((item) => _closePosition(item['ticket'], item['symbol'], silent: true));
    await Future.wait(futures);
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Bulk Operation Completed"),
          backgroundColor: Colors.green,
      ));
    }
  }

  Future<void> _closePosition(int ticket, String symbol, {bool silent = false}) async {
    final url = Uri.parse('${ApiConfig.baseUrl}/close');
    try {
      final response = await http.post(
        url, 
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"login": widget.login, "ticket": ticket, "symbol": symbol})
      );
      
      if (!silent && mounted) {
        if (response.statusCode == 200) {
           ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Order Closed Success"), backgroundColor: Colors.green));
        } else {
           ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Close Failed: ${response.body}"), backgroundColor: Colors.red));
        }
      }
    } catch (e) {
       if (!silent && mounted) {
           ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e"), backgroundColor: Colors.red));
        }
    }
  }
  
  // ... showOptions ...
   void _showOptions(BuildContext context, Map<String, dynamic> item) {
     showModalBottomSheet(
       context: context,
       backgroundColor: const Color(0xFF1E222D),
       shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
       builder: (ctx) {
         return Container(
           padding: const EdgeInsets.symmetric(vertical: 20),
           child: Column(
             mainAxisSize: MainAxisSize.min,
             children: [
                // Header
                Text("${item['symbol']} #${item['ticket']}", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 10),
                const Divider(color: Colors.white10),
                
                // Option 1: Close
                ListTile(
                  leading: const Icon(Icons.close, color: Colors.orange),
                  title: const Text("Close Order", style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _closePosition(item['ticket'], item['symbol']);
                  },
                ),
                
                // Option 2: Chart
                ListTile(
                  leading: const Icon(Icons.show_chart, color: Colors.blue),
                  title: const Text("Chart", style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(ctx);
                    widget.onSymbolSelected?.call(item['symbol']);
                  },
                ),

                // Option 3: Bulk
                ListTile(
                  leading: const Icon(Icons.layers, color: Colors.purpleAccent),
                   title: Text("Close All ${item['symbol']} (${item['status'] == 'OPEN' ? 'Positions' : 'Pending'})", style: const TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _bulkClose(item['symbol'], item['status']);
                  },
                ),
             ],
           ),
         );
       }
     );
  }

  Color _getProfitColor(double profit) {
    if (profit > 0) return Colors.blue;
    if (profit < 0) return Colors.red;
    return Colors.grey;
  }

  @override
  Widget build(BuildContext context) {
    // Calculate Stats
    double balance = _accountInfo?['balance'] ?? 0.0;
    double equity = _accountInfo?['equity'] ?? 0.0;
    double margin = _accountInfo?['margin'] ?? 0.0;
    double freeMargin = _accountInfo?['margin_free'] ?? 0.0;
    double marginLevel = _accountInfo?['margin_level'] ?? 0.0;
    double totalProfit = _accountInfo?['profit'] ?? 0.0;

    return Scaffold(
      backgroundColor: const Color(0xFF151924),
      body: SafeArea(
        child: Column(
          children: [
            // === 0. TOP APP BAR (Menu) ===
             Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.menu, color: Colors.white),
                    onPressed: () => widget.onMenuTap?.call(),
                  ),
                  const Text("Trade", style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                  const Spacer(),
                ],
              ),
            ),

            // === 1. ACCOUNT INFO ===
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: const BoxDecoration(
                color: Color(0xFF1E222D),
                border: Border(bottom: BorderSide(color: Colors.white10)),
              ),
              child: Column(
                children: [
                   // Account Info Summary
                   Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                       _buildInfoItem("Balance", balance),
                       _buildInfoItem("Equity", equity),
                    ],
                   ),
                   const SizedBox(height: 12),
                   const Divider(color: Colors.white10),
                   const SizedBox(height: 12),
                   
                   // Detail Stats
                   Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildInfoItem("Margin", margin, isSmall: true),
                      _buildInfoItem("Free Margin", freeMargin, isSmall: true),
                      _buildInfoItem("Level (%)", marginLevel, isSmall: true),
                    ],
                   ),
                   
                   const SizedBox(height: 16),
                   // Total Profit Banner
                   Container(
                     width: double.infinity,
                     padding: const EdgeInsets.symmetric(vertical: 8),
                     decoration: BoxDecoration(
                        color: _getProfitColor(totalProfit).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8)
                     ),
                     child: Column(
                       children: [
                         const Text("Total Profit", style: TextStyle(color: Colors.grey, fontSize: 11)),
                         Text(
                            "${totalProfit >= 0 ? '+' : ''}${_currencyFmt.format(totalProfit)}",
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: _getProfitColor(totalProfit),
                            ),
                          ),
                       ],
                     ),
                   )
                ],
              ),
            ),


            // === 2. LISTS (Positions & Orders) ===
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  // Positions Header
                  if (_positions.isNotEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Text("POSITIONS", style: TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.bold)),
                    ),
                  
                  ..._positions.map((pos) => _buildPositionCard(pos)).toList(),

                  // Orders Header
                  if (_orders.isNotEmpty) ...[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Text("ORDERS", style: TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.bold)),
                    ),
                    ..._orders.map((ord) => _buildOrderCard(ord)).toList(),
                  ]
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoItem(String label, double value, {bool isSmall = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: Colors.grey, fontSize: isSmall ? 11 : 13)),
        const SizedBox(height: 2),
        Text(
          _currencyFmt.format(value),
          style: TextStyle(
            color: Colors.white,
            fontSize: isSmall ? 13 : 18,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  String _formatPrice(dynamic priceVal, String symbol) {
     double price = priceVal is num ? priceVal.toDouble() : double.tryParse(priceVal.toString()) ?? 0.0;
     if (symbol.toUpperCase().contains('JPY') || symbol.toUpperCase().contains('XAU') || symbol.toUpperCase().contains('BTC')) {
       return price.toStringAsFixed(2);
     }
     return price.toStringAsFixed(5);
  }

  Widget _buildPositionCard(Map<String, dynamic> pos) {
    final bool isBuy = pos['type'].toString().contains('BUY');
    final double profit = pos['profit'] is num ? (pos['profit'] as num).toDouble() : 0.0;
    
    // Add InkWell for Touch & Hold
    return InkWell(
      onLongPress: () => _showOptions(context, pos),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 1), 
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: const BoxDecoration(
          color: Color(0xFF1E222D),
          border: Border(bottom: BorderSide(color: Colors.white10, width: 0.5)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Left: Symbol, Type, ID
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(pos['symbol'], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(width: 8),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(isBuy ? "BUY" : "SELL", style: TextStyle(color: isBuy ? Colors.blue : Colors.red, fontWeight: FontWeight.bold, fontSize: 12)),
                    const SizedBox(width: 6),
                    Text(pos['volume'].toString(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                  ],
                )
              ],
            ),
            
            // Right: Profit and Price Flow
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Profit
                Text(
                  "${profit >= 0 ? '+' : ''}${_currencyFmt.format(profit)}",
                  style: TextStyle(
                    color: _getProfitColor(profit),
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                // Price Arrow
                Row(
                  children: [
                     Text(
                      _formatPrice(pos['price_open'], pos['symbol']),
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4),
                      child: Icon(Icons.arrow_right_alt, color: Colors.grey, size: 14),
                    ),
                    Text(
                      _formatPrice(pos['price_current'], pos['symbol']),
                      style: TextStyle(color: isBuy ? Colors.blue : Colors.red, fontSize: 12),
                    ),
                  ],
                )
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOrderCard(Map<String, dynamic> ord) {
    final bool isBuy = ord['type'].toString().contains('BUY');
    
    // Add InkWell for Touch & Hold
    return InkWell(
      onLongPress: () => _showOptions(context, ord),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: const BoxDecoration(
          color: Color(0xFF1E222D),
          border: Border(bottom: BorderSide(color: Colors.white10, width: 0.5)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(ord['symbol'], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(ord['type'], style: TextStyle(color: isBuy ? Colors.blue : Colors.red, fontWeight: FontWeight.bold, fontSize: 12)),
                    const SizedBox(width: 6),
                    Text(ord['volume'].toString(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                  ],
                )
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const Text("PLACED", style: TextStyle(color: Colors.orange, fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(
                  "@ ${_formatPrice(ord['price_open'], ord['symbol'])}",
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
