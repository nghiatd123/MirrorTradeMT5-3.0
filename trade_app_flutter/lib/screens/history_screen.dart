import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:intl/intl.dart';

class HistoryScreen extends StatefulWidget {
  final VoidCallback? onMenuTap;
  const HistoryScreen({super.key, this.onMenuTap});
  
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  bool _isLoading = true;
  String _activeTab = "POSITIONS"; // POSITIONS, ORDERS, DEALS
  Map<String, dynamic> _summary = {};
  List<dynamic> _deals = [];
  List<dynamic> _orders = [];
  
  DateTimeRange? _dateRange;
  String? _symbolFilter;

  final NumberFormat _currencyFmt = NumberFormat("#,##0.00", "en_US");

  @override
  void initState() {
    super.initState();
    _fetchHistory();
  }

  Future<void> _fetchHistory() async {
    setState(() => _isLoading = true);
    try {
      final url = Uri.parse('http://192.168.1.41:8000/trade_history');
      
      String group = _activeTab; 
      
      final body = {
        "group": group,
        "from_date": _dateRange?.start.toIso8601String(),
        "to_date": _dateRange?.end.toIso8601String(),
      };

      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(body)
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (mounted) {
          setState(() {
            _summary = data['summary'];
            if (_activeTab == "POSITIONS") {
                 _deals = data['positions'] ?? [];
            } else {
                 _deals = data['deals'] ?? [];
            }
            _orders = data['orders'] ?? [];
            _isLoading = false;
          });
        }
      } else {
        throw Exception("Failed to load history");
      }
    } catch (e) {
      print("History Error: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _onTabChange(String tab) {
      if (_activeTab == tab) return;
      setState(() => _activeTab = tab);
      _fetchHistory();
  }

  void _showCalendar() {
      showModalBottomSheet(
          context: context,
          backgroundColor: const Color(0xFF1E222D),
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
          builder: (ctx) {
              final now = DateTime.now();
              return Container(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                      _buildDateOption(ctx, "Today", DateTime(now.year, now.month, now.day), now),
                      _buildDateOption(ctx, "Last Week", now.subtract(const Duration(days: 7)), now),
                      _buildDateOption(ctx, "Last Month", now.subtract(const Duration(days: 30)), now),
                      _buildDateOption(ctx, "Last 3 Months", now.subtract(const Duration(days: 90)), now),
                      const Divider(color: Colors.white10),
                      ListTile(
                          leading: const Icon(Icons.calendar_month, color: Colors.white),
                          title: const Text("Custom Period", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                          onTap: () {
                              Navigator.pop(ctx);
                              _showCustomRangePicker();
                          },
                      )
                  ],
                ),
              );
          }
      );
  }

  Widget _buildDateOption(BuildContext ctx, String label, DateTime start, DateTime end) {
      final String subtitle = "${DateFormat('dd/MM/yyyy').format(start)} - ${DateFormat('dd/MM/yyyy').format(end)}";
      final bool isSelected = _dateRange != null && 
                              DateFormat('yyyyMMdd').format(_dateRange!.start) == DateFormat('yyyyMMdd').format(start) &&
                              DateFormat('yyyyMMdd').format(_dateRange!.end) == DateFormat('yyyyMMdd').format(end);
                              
      return ListTile(
         leading: Icon(Icons.calendar_today, color: isSelected ? Colors.blue : Colors.grey),
         title: Text(label, style: TextStyle(color: isSelected ? Colors.blue : Colors.white, fontWeight: FontWeight.bold)),
         subtitle: Text(subtitle, style: const TextStyle(color: Colors.grey, fontSize: 12)),
         trailing: isSelected ? const Icon(Icons.check, color: Colors.blue) : null,
         onTap: () {
             setState(() => _dateRange = DateTimeRange(start: start, end: end));
             Navigator.pop(ctx);
             _fetchHistory();
         },
      );
  }

  void _showCustomRangePicker() async {
      final now = DateTime.now();
      final picked = await showDateRangePicker(
          context: context,
          firstDate: DateTime(2020),
          lastDate: now.add(const Duration(days: 1)),
          initialDateRange: _dateRange ?? DateTimeRange(start: now.subtract(const Duration(days: 90)), end: now),
          builder: (context, child) {
            return Theme(
              data: ThemeData.dark().copyWith(
                colorScheme: const ColorScheme.dark(
                  primary: Colors.blue,
                  onPrimary: Colors.white,
                  surface: Color(0xFF1E222D),
                  onSurface: Colors.white,
                ),
                dialogBackgroundColor: const Color(0xFF151924),
              ),
              child: child!,
            );
          }
      );
      if (picked != null) {
          setState(() => _dateRange = picked);
          _fetchHistory();
      }
  }

  void _showFilter() {
      final Set<String> symbols = {};
      for (var i in _deals) { if (i['symbol'] != null) symbols.add(i['symbol']); }
      for (var i in _orders) { if (i['symbol'] != null) symbols.add(i['symbol']); }
      
      showModalBottomSheet(
          context: context,
          backgroundColor: const Color(0xFF1E222D),
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
          builder: (ctx) {
              return Container(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                      const Text("Filter Symbol", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
                      const SizedBox(height: 16),
                      ListTile(
                        leading: const Icon(Icons.filter_list_off, color: Colors.blue),
                        title: const Text("All Symbols", style: TextStyle(color: Colors.white)), 
                        onTap: (){
                          setState(() => _symbolFilter = null);
                          Navigator.pop(ctx);
                      }),
                      const Divider(color: Colors.white10),
                      Expanded(
                        child: ListView(
                          shrinkWrap: true,
                          children: symbols.map((s) => ListTile(
                              title: Text(s, style: const TextStyle(color: Colors.white)),
                              trailing: _symbolFilter == s ? const Icon(Icons.check, color: Colors.blue) : null,
                              onTap: (){
                                  setState(() => _symbolFilter = s);
                                  Navigator.pop(ctx);
                              },
                          )).toList(),
                        ),
                      )
                  ]
                ),
              );
          }
      );
  }

  Color _getProfitColor(double value) {
    if (value > 0) return Colors.blue;
    if (value < 0) return Colors.red;
    return Colors.white;
  }

  String _formatDate(dynamic timestamp) {
      if (timestamp == null) return "-";
      if (timestamp is int) {
          return DateFormat("yyyy-MM-dd HH:mm").format(
             DateTime.fromMillisecondsSinceEpoch(timestamp * 1000, isUtc: true)
          );
      }
      return timestamp.toString();
  }

  @override
  Widget build(BuildContext context) {
    List<dynamic> currentList = (_activeTab == "ORDERS") ? _orders : _deals;
    if (_symbolFilter != null) {
      currentList = currentList.where((i) => i['symbol'] == _symbolFilter).toList();
    }

    return Scaffold(
      backgroundColor: const Color(0xFF151924),
      appBar: AppBar(
        backgroundColor: const Color(0xFF151924),
        leading: IconButton(
            icon: const Icon(Icons.menu, color: Colors.white),
            onPressed: () => widget.onMenuTap?.call(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("History", style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
            Text(_symbolFilter ?? "All Symbols", style: const TextStyle(color: Colors.white54, fontSize: 14)),
          ],
        ),
        actions: [
          IconButton(icon: const Icon(Icons.refresh, color: Colors.white), onPressed: _fetchHistory),
          IconButton(icon: const Icon(Icons.filter_list, color: Colors.white), onPressed: _showFilter),
          IconButton(icon: const Icon(Icons.calendar_month, color: Colors.white), onPressed: _showCalendar),
        ],
        bottom: PreferredSize(
           preferredSize: const Size.fromHeight(40),
           child: Padding(
             padding: const EdgeInsets.symmetric(horizontal: 16),
             child: Row(
               mainAxisAlignment: MainAxisAlignment.spaceBetween,
               children: [
                 _buildTab("POSITIONS", "POSITIONS"),
                 _buildTab("ORDERS", "ORDERS"),
                 _buildTab("DEALS", "DEALS"),
               ],
             ),
           ),
        ),
      ),
      body: _isLoading 
         ? const Center(child: CircularProgressIndicator())
         : Column(
            children: [
               if (_activeTab != "ORDERS") _buildSummary(),

               Expanded(
                 child: currentList.isEmpty 
                    ? const Center(child: Text("No Data", style: TextStyle(color: Colors.white54)))
                    : ListView.separated(
                        padding: const EdgeInsets.all(8),
                        itemCount: currentList.length,
                        separatorBuilder: (_, __) => const Divider(color: Colors.white10),
                        itemBuilder: (ctx, index) {
                          return _buildItem(currentList[index]);
                        },
                      ),
               )
            ],
         ),
    );
  }

  Widget _buildTab(String key, String title) {
     final bool isActive = _activeTab == key;
     return InkWell(
       onTap: () => _onTabChange(key),
       child: Container(
         padding: const EdgeInsets.only(bottom: 8),
         decoration: isActive ? const BoxDecoration(
           border: Border(bottom: BorderSide(color: Colors.blue, width: 2))
         ) : null,
         child: Text(title, style: TextStyle(
           color: isActive ? Colors.white : Colors.grey,
           fontWeight: FontWeight.bold,
           fontSize: 12
         )),
       ),
     );
  }

  Widget _buildSummary() {
    return Container(
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Column(
        children: [
          _buildSummaryRow("Profit:", _summary['profit'] ?? 0.0, isColor: true),
          _buildSummaryRow("Deposit:", _summary['deposit'] ?? 0.0),
          _buildSummaryRow("Swap:", _summary['swap'] ?? 0.0),
          _buildSummaryRow("Commission:", _summary['commission'] ?? 0.0),
          const SizedBox(height: 8),
          const Divider(color: Colors.white10),
           _buildSummaryRow("Balance:", _summary['balance'] ?? 0.0, isBold: true),
        ],
      ),
    );
  }

  Widget _buildSummaryRow(String label, double value, {bool isBold = false, bool isColor = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
          Text(
            _currencyFmt.format(value), 
            style: TextStyle(
              color: isColor ? _getProfitColor(value) : Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 14
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItem(Map<String, dynamic> item) {
     if (_activeTab == "ORDERS") {
        return _buildOrderItem(item);
     } else if (_activeTab == "POSITIONS") {
        return _buildPositionItem(item);
     } else {
        return _buildDealItem(item);
     }
  }

  Widget _buildPositionItem(Map<String, dynamic> pos) {
      final double profit = pos['profit'];
      final bool isBuy = pos['type'].toString().contains("BUY");
      
      return Padding(
       padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
       child: Column(
         crossAxisAlignment: CrossAxisAlignment.start,
         children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                   children: [
                      Text(pos['symbol'], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                      const SizedBox(width: 8),
                      Text(pos['type'], style: TextStyle(color: isBuy ? Colors.blue : Colors.red, fontWeight: FontWeight.bold, fontSize: 14)),
                      const SizedBox(width: 4),
                      Text(pos['volume'].toString(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                   ]
                ),
                Text(
                  "${profit >= 0 ? '+' : ''}${_currencyFmt.format(profit)}",
                  style: TextStyle(color: _getProfitColor(profit), fontWeight: FontWeight.bold, fontSize: 16)
                )
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                 Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                        Text(_formatDate(pos['open_time']), style: const TextStyle(color: Colors.white54, fontSize: 11)),
                        Text("@ ${pos['open_price']}", style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    ]
                 ),
                 const Icon(Icons.arrow_forward, color: Colors.grey, size: 14),
                 Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                        Text(_formatDate(pos['close_time']), style: const TextStyle(color: Colors.white54, fontSize: 11)),
                        Text("@ ${pos['close_price']}", style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    ]
                 ),
              ]
            )
         ],
       ),
     );
  }

  Widget _buildOrderItem(Map<String, dynamic> order) {
      Color stateColor = Colors.grey;
      if (order['state'] == 'FILLED') stateColor = Colors.green;
      if (order['state'] == 'CANCELED') stateColor = Colors.red;
      
      return Padding(
       padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
       child: Column(
         crossAxisAlignment: CrossAxisAlignment.start,
         children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(order['symbol'], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                Text(order['state'], style: TextStyle(color: stateColor, fontWeight: FontWeight.bold, fontSize: 14)),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Text(order['type'], style: TextStyle(color: order['type'].contains('BUY') ? Colors.blue : Colors.red, fontSize: 13, fontWeight: FontWeight.bold)),
                const SizedBox(width: 4),
                Text(order['volume'].toString(), style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                const Spacer(),
                Text(_formatDate(order['time']), style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
            Text("@ ${order['price']}", style: const TextStyle(color: Colors.white70, fontSize: 13)),
         ],
       ),
     );
  }

  Widget _buildDealItem(Map<String, dynamic> deal) {
     final bool isDeposit = deal['type'] == 'BALANCE';
     final double profit = deal['profit'];

     return Padding(
       padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
       child: Column(
         crossAxisAlignment: CrossAxisAlignment.start,
         children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (isDeposit)
                   const Text("Balance", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16))
                else
                   Text(deal['symbol'], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                
                Text(
                  "${profit >= 0 ? '+' : ''}${_currencyFmt.format(profit)}",
                  style: TextStyle(color: _getProfitColor(profit), fontWeight: FontWeight.bold, fontSize: 16)
                )
              ],
            ),
            const SizedBox(height: 4),
            if (!isDeposit) ...[
                Row(
                  children: [
                    Text(deal['type'], style: TextStyle(color: deal['type'] == 'BUY' ? Colors.blue : Colors.red, fontSize: 13, fontWeight: FontWeight.bold)),
                    const SizedBox(width: 4),
                    Text(deal['volume'].toString(), style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Text(_formatDate(deal['time']), style: const TextStyle(color: Colors.white54, fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                     Text("${deal['price']} -> ", style: const TextStyle(color: Colors.white70, fontSize: 13)),
                     const Text("closed", style: TextStyle(color: Colors.white30, fontSize: 13)),
                  ],
                )
            ] else ...[
                 Row(
                   mainAxisAlignment: MainAxisAlignment.spaceBetween,
                   children: [
                      Text(deal['comment'] ?? "Deposit", style: const TextStyle(color: Colors.white70, fontSize: 13)),
                      Text(_formatDate(deal['time']), style: const TextStyle(color: Colors.white54, fontSize: 12)),
                   ],
                 )
            ]
         ],
       ),
     );
  }
}
