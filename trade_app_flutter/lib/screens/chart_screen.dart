import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:async';

class ChartScreen extends StatefulWidget {
  final VoidCallback? onMenuTap;
  const ChartScreen({super.key, this.onMenuTap});

  @override
  State<ChartScreen> createState() => ChartScreenState();
}

class ChartScreenState extends State<ChartScreen> {
  final List<String> _symbols = ["EURUSD", "GBPUSD", "USDJPY", "XAUUSD", "BTCUSD"];
  String _symbol = "XAUUSD"; 
  
  late final WebViewController _controller;
  bool _isChartReady = false; 

  bool _isLoading = true;

  WebSocketChannel? _quotesChannel;
  WebSocketChannel? _positionsChannel;
  double _volume = 0.01;
  final List<String> _timeframes = ["M1", "M5", "M15", "M30", "H1", "H4", "D1"];
  String _timeframe = "M1";
  
  // Order State
  String _orderTab = 'Market'; 
  final TextEditingController _lotCtrl = TextEditingController(text: "0.01");
  final TextEditingController _limitPriceCtrl = TextEditingController();
  final TextEditingController _slController = TextEditingController();
  final TextEditingController _tpController = TextEditingController();
  
  List<dynamic> _positions = [];

  // Candle State for Real-time aggregation
  int? _lastCandleTime;
  double _lastOpen = 0;
  double _lastHigh = 0;
  double _lastLow = 0;
  double _lastClose = 0;

  @override
  void initState() {
    super.initState();
    _loadVolume();
    
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF1C212E))
      ..addJavaScriptChannel(
        'PositionModified',
        onMessageReceived: (JavaScriptMessage message) {
           _handlePositionModified(message.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (String url) {
             _isChartReady = true;
             _fetchCandles(); 
          },
        ),
      )
      ..loadFlutterAsset('assets/chart/index.html');

    _connectPositionsWebSocket();
  }
  
  @override
  void dispose() {
     if (_quotesChannel != null) _quotesChannel!.sink.close();
     if (_positionsChannel != null) _positionsChannel!.sink.close();
     _slController.dispose();
     _tpController.dispose();
     _lotCtrl.dispose();
     _limitPriceCtrl.dispose();
     super.dispose();
  }

  void changeSymbol(String newSymbol) {
    if (_symbol != newSymbol) {
      setState(() {
        _symbol = newSymbol;
        _isLoading = true;
        // Reset state
        _lastCandleTime = null;
      });
      _fetchCandles();
    }
  }

  void _handlePositionModified(String message) {
      try {
          final data = jsonDecode(message);
          int ticket = data['ticket'];
          String type = data['type']; // 'SL' or 'TP'
          double newPrice = (data['price'] as num).toDouble();
          
          if (type == 'CLOSE') {
              _closePosition(ticket);
              return;
          }

          var pos = _positions.firstWhere((p) => p['ticket'] == ticket, orElse: () => null);
          if (pos != null) {
              double sl = (pos['sl'] as num).toDouble();
              double tp = (pos['tp'] as num).toDouble();
              
              if (type == 'SL') sl = newPrice;
              if (type == 'TP') tp = newPrice;
              
              _modifyPosition(ticket, _symbol, sl, tp);
          }
      } catch (e) {
          print("Error parsing bridge message: $e");
      }
  }

  Future<void> _closePosition(int ticket) async {
       // Use dedicated /close endpoint which handles volume lookup on backend
       final url = Uri.parse('http://192.168.1.41:8000/close'); 
       
       try {
          final response = await http.post(
            url,
            headers: {"Content-Type": "application/json"},
            body: jsonEncode({
              "ticket": ticket,
              "symbol": _symbol,
            }),
          );
           if (response.statusCode == 200) {
               _showResult("Position Closed", Colors.orange);
               _fetchPositions();
           } else {
               // Parse error detail
               String errorMsg = "Close Failed: ${response.statusCode}";
               try {
                  final errData = jsonDecode(response.body);
                  if (errData['detail'] != null) {
                     errorMsg = "Close Failed: ${errData['detail']}";
                  }
               } catch(_) {}
               _showResult(errorMsg, Colors.red);
           }
       } catch (e) {
           _showResult("Error closing: $e", Colors.red);
       }
  }

  Future<void> _fetchCandles() async {
    if (!_isChartReady) return;

    setState(() => _isLoading = true);
    final url = Uri.parse('http://192.168.1.41:8000/history?symbol=$_symbol&timeframe=$_timeframe&count=500');
    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final Map<String, dynamic> json = jsonDecode(response.body);
        if (json['status'] == 'success') {
          final List<dynamic> data = json['data'];
          
          List<Map<String, dynamic>> processedData = [];
          
          // Pre-process for TradingView (Ensure milliseconds/seconds consistency)
          // TradingView expects seconds for 'time' field relative to Unix Epoch
          for(var item in data) {
              // item['time'] is likely seconds from backend? Or microseconds?
              // Previous code: DateTime.fromMicrosecondsSinceEpoch(item['time'] * 1000000) was wrong if item['time'] was already microseconds
              // Actually MT5 usually works in seconds. Python backend likely returns seconds.
              // Let's assume seconds.
              num t = item['time']; 
              processedData.add({
                  "time": t,
                  "open": item['open'],
                  "high": item['high'],
                  "low": item['low'],
                  "close": item['close']
              });
          }
           
           // Update local state for aggregation
          if (processedData.isNotEmpty) {
             final last = processedData.last;
             _lastCandleTime = (last['time'] as num).toInt();
             _lastOpen = (last['open'] as num).toDouble();
             _lastHigh = (last['high'] as num).toDouble();
             _lastLow = (last['low'] as num).toDouble();
             _lastClose = (last['close'] as num).toDouble();
          }

          final jsonString = jsonEncode(processedData);
          _controller.runJavaScript("loadHistory('$jsonString')");
          
          if (mounted) {
            setState(() => _isLoading = false);
            _connectWebSocket();
            _pushPositionsToChart();
          }
        }
      }
    } catch (e) {
      print("Error fetching history: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _fetchPositions() async {
    try {
      final response = await http.get(Uri.parse('http://192.168.1.41:8000/positions'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (mounted) {
            setState(() {
            _positions = data['positions'];
            });
            _pushPositionsToChart();
        }
      }
    } catch (e) {
      print("Error fetching positions: $e");
    }
  }

  void _connectPositionsWebSocket() {
    if (_positionsChannel != null) _positionsChannel!.sink.close();
    _positionsChannel = WebSocketChannel.connect(Uri.parse('ws://192.168.1.41:8000/ws/positions'));
    _positionsChannel!.stream.listen((message) {
      try {
        final data = jsonDecode(message);
        if (data is Map && data.containsKey('positions')) {
           if (mounted) {
             setState(() {
                _positions = (data['positions'] as List).where((p) => p['symbol'] == _symbol).toList();
             });
             _pushPositionsToChart();
           }
        }
      } catch (e) { }
    });
  }

  void _pushPositionsToChart() {
      if (!_isChartReady) return;
      final relevantPositions = _positions.where((p) => p['symbol'].toString().toUpperCase() == _symbol.toUpperCase()).toList();
      final jsonString = jsonEncode(relevantPositions);
      _controller.runJavaScript("updatePositions('$jsonString')");
  }

  void _connectWebSocket() {
    if (_quotesChannel != null) _quotesChannel!.sink.close();
    _quotesChannel = WebSocketChannel.connect(Uri.parse('ws://192.168.1.41:8000/ws/quotes'));
    _quotesChannel!.stream.listen((message) {
      try {
        final data = jsonDecode(message);
        if (data is Map && data.containsKey('symbol')) {
           if (data['symbol'] == _symbol || (data['mt5_symbol'] != null && data['mt5_symbol'] == _symbol)) {
              final double price = (data['bid'] as num).toDouble();
              final num timeNum = data['time'] as num;
              _processTick(price, timeNum.toInt());
           }
        }
      } catch (e) { }
    });
  }
  
  double _currentBid = 0.0;

  void _processTick(double price, int serverTime) {
      if (!_isChartReady) return;
      _currentBid = price; // Track for defaults
      
      int period = 60;
      switch (_timeframe) {
        case "M1": period = 60; break;
        case "M5": period = 300; break;
        case "M15": period = 900; break;
        case "M30": period = 1800; break;
        case "H1": period = 3600; break;
        case "H4": period = 14400; break;
        case "D1": period = 86400; break;
      }
      
      final int currentCandleTime = serverTime - (serverTime % period);
      
      if (_lastCandleTime == null || currentCandleTime > _lastCandleTime!) {
          // New Candle
          _lastCandleTime = currentCandleTime;
          _lastOpen = price;
          _lastHigh = price;
          _lastLow = price;
          _lastClose = price;
      } else {
          // Update Existing
          if (price > _lastHigh) _lastHigh = price;
          if (price < _lastLow) _lastLow = price;
          _lastClose = price;
      }
      
      // Update JS
      // TradingView update format: { time: ..., open: ..., high: ..., low: ..., close: ... }
      _controller.runJavaScript("""
         if (window.updateLastCandle) {
             window.updateLastCandle($currentCandleTime, $_lastOpen, $_lastHigh, $_lastLow, $_lastClose);
         }
      """);
  }

  Future<void> _loadVolume() async {
      final prefs = await SharedPreferences.getInstance();
      double? saved = prefs.getDouble('last_volume');
      if (saved != null) {
          setState(() {
              _volume = saved;
              _lotCtrl.text = saved.toString();
          });
      }
  }

  Future<void> _saveVolume(double vol) async {
       final prefs = await SharedPreferences.getInstance();
       prefs.setDouble('last_volume', vol);
  }

  Future<void> _placeOrder(String action) async {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Sending $action..."), duration: const Duration(milliseconds: 500)));
    final url = Uri.parse('http://192.168.1.41:8000/trade');
    
    double vol = double.tryParse(_lotCtrl.text) ?? 0.01;
    _saveVolume(vol);
    setState(() => _volume = vol); 

    double finalPrice = 0.0;
    if (_orderTab == 'Limit') {
        finalPrice = double.tryParse(_limitPriceCtrl.text) ?? 0.0;
        if (finalPrice <= 0) {
            _showResult("Invalid Limit Price", Colors.red);
            return;
        }
    } else {
        finalPrice = _currentBid; // Approximate for Market TP/SL calc
    }

    // Default SL/TP Logic (0.15%) REMOVED - User acts on text fields
    double sl = double.tryParse(_slController.text) ?? 0.0;
    double tp = double.tryParse(_tpController.text) ?? 0.0;

    try {
      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "action": action, 
          "symbol": _symbol, 
          "volume": vol, 
          "price": _orderTab == 'Limit' ? finalPrice : 0.0, // Backend handles Market price
          "sl": sl,
          "tp": tp,
          "order_mode": _orderTab.toUpperCase()
        }),
      );
      if (response.statusCode == 200) {
         final data = jsonDecode(response.body);
         _showResult(data['status'] == 'success' ? "Success" : "Error: ${data['message']}", 
           data['status'] == 'success' ? Colors.green : Colors.red);
         if (data['status'] == 'success' && mounted) _fetchPositions();
       } else {
         String errorMsg = "Order Failed: ${response.statusCode}";
         try {
            final errData = jsonDecode(response.body);
            if (errData['detail'] != null) {
               errorMsg = errData['detail'];
            }
         } catch(_) {}
         _showResult(errorMsg, Colors.red);
       }
    } catch (e) {
       _showResult("Error: $e", Colors.red);
    }
  }
  
  Future<void> _modifyPosition(int ticket, String symbol, double sl, double tp) async {
    final url = Uri.parse('http://192.168.1.41:8000/modify');
    try {
      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "ticket": ticket,
          "symbol": symbol,
          "sl": sl,
          "tp": tp
        }),
      );
      if (response.statusCode != 200) {
         _showResult("Modify Failed", Colors.red);
      } else {
         ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Modified SL/TP"), duration: Duration(milliseconds: 500)));
      }
    } catch (e) {
       _showResult("Error: $e", Colors.red);
    }
  }

  void _showResult(String msg, Color color) {
     if(!mounted) return;
     ScaffoldMessenger.of(context).hideCurrentSnackBar();
     ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  void _updateVolume(double change) {
       double current = double.tryParse(_lotCtrl.text) ?? 0.01;
       double newVal = (current + change).clamp(0.01, 100.0);
       newVal = double.parse(newVal.toStringAsFixed(2));
       setState(() {
         _lotCtrl.text = newVal.toString();
         _volume = newVal;
       });
       _saveVolume(newVal); 
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1C212E),
        leading: IconButton(
           icon: const Icon(Icons.menu, color: Colors.white), 
           onPressed: () => widget.onMenuTap?.call()
        ),
        title: DropdownButton<String>(
          value: _symbol,
          dropdownColor: const Color(0xFF2B303F),
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
          underline: Container(), 
          icon: const Icon(Icons.arrow_drop_down, color: Colors.white),
          items: _symbols.map((String s) {
            return DropdownMenuItem<String>(value: s, child: Text(s));
          }).toList(),
          onChanged: (String? newValue) {
            if (newValue != null) {
              changeSymbol(newValue);
            }
          },
        ),
        actions: [
          DropdownButton<String>(
            value: _timeframe,
            dropdownColor: const Color(0xFF2B303F),
            style: const TextStyle(color: Colors.white, fontSize: 14),
            underline: Container(),
            items: _timeframes.map((String tf) => DropdownMenuItem(value: tf, child: Text(tf))).toList(),
            onChanged: (v) { 
              if(v!=null) { 
                  setState(() => _timeframe = v);
                  _fetchCandles();
              }
            } 
          ),
          const SizedBox(width: 10),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
                children: [
                    WebViewWidget(controller: _controller),
                    if (_isLoading) 
                        const Center(child: CircularProgressIndicator())
                ],
            )
          ),
          Container(
             color: const Color(0xFF1E222D),
             padding: const EdgeInsets.all(8),
             child: Column(
               children: [
                  Row(
                    children: [
                         Expanded(child: _buildTab("Market", _orderTab == 'Market')),
                         Expanded(child: _buildTab("Limit", _orderTab == 'Limit')),
                    ]
                  ),
                  const SizedBox(height: 8),
                  if (_orderTab == 'Limit')
                    Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: TextField(
                            controller: _limitPriceCtrl,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                                labelText: "Limit Price",
                                labelStyle: TextStyle(color: Colors.grey),
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 0)
                            ),
                        ),
                    ),
                  Row(
                     children: [
                        IconButton(onPressed: () => _updateVolume(-0.01), icon: const Icon(Icons.remove, color: Colors.white)),
                        SizedBox(
                           width: 60,
                           child: TextField(
                              controller: _lotCtrl,
                              textAlign: TextAlign.center,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                              decoration: const InputDecoration(border: InputBorder.none),
                              onChanged: (val) {
                                  double? v = double.tryParse(val);
                                  if (v != null) _volume = v;
                              },
                           )
                        ),
                        IconButton(onPressed: () => _updateVolume(0.01), icon: const Icon(Icons.add, color: Colors.white)),
                        const SizedBox(width: 10),
                        Expanded(child: TextField(controller: _slController, style: const TextStyle(color: Colors.white, fontSize: 12), decoration: const InputDecoration(labelText: "SL", labelStyle: TextStyle(color: Colors.grey), border: OutlineInputBorder()))),
                        const SizedBox(width: 5),
                        Expanded(child: TextField(controller: _tpController, style: const TextStyle(color: Colors.white, fontSize: 12), decoration: const InputDecoration(labelText: "TP", labelStyle: TextStyle(color: Colors.grey), border: OutlineInputBorder()))),
                     ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                     children: [
                        Expanded(child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.blue), onPressed: () => _placeOrder('BUY'), child: const Text("BUY", style: TextStyle(color: Colors.white)))),
                        const SizedBox(width: 10),
                         Expanded(child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.red), onPressed: () => _placeOrder('SELL'), child: const Text("SELL", style: TextStyle(color: Colors.white)))),
                     ],
                  )
               ],
             ),
          )
        ],
      )
    );
  }

  Widget _buildTab(String title, bool isActive) {
      return GestureDetector(
          onTap: () {
             setState(() {
                _orderTab = title;
                if (title == 'Limit' && _currentBid > 0) {
                    _limitPriceCtrl.text = _currentBid.toString();
                    _slController.clear();
                    _tpController.clear();
                } else if (title == 'Market') {
                    _slController.clear();
                    _tpController.clear();
                }
             });
          },
          child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: isActive ? Colors.blue.withOpacity(0.2) : Colors.transparent,
                  border: isActive ? Border(bottom: BorderSide(color: Colors.blue, width: 2)) : null
              ),
              child: Text(title, style: TextStyle(color: isActive ? Colors.blue : Colors.grey, fontWeight: FontWeight.bold))
          )
      );
  }
}
