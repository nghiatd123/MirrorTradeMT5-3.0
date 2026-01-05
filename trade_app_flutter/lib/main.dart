import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/chart_screen.dart';
import 'screens/trade_screen.dart';
import 'screens/quotes_screen.dart';
import 'screens/login_screen.dart';
import 'screens/history_screen.dart';
import 'widgets/side_menu.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final bool isLoggedIn = prefs.getBool('is_logged_in') ?? false;
  
  runApp(MyApp(isLoggedIn: isLoggedIn));
}

class MyApp extends StatelessWidget {
  final bool isLoggedIn;
  const MyApp({super.key, required this.isLoggedIn});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MT5 Clone',
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.blue,
        scaffoldBackgroundColor: const Color(0xFF151924), // cTrader/MT5 dark bg
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1E222D),
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: Color(0xFF1E222D),
          selectedItemColor: Colors.blue,
          unselectedItemColor: Colors.grey,
          type: BottomNavigationBarType.fixed,
        ),
      ),
      home: isLoggedIn ? const MainScreen() : const LoginScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 2; // Default to Trade Screen
  final GlobalKey<ChartScreenState> _chartKey = GlobalKey<ChartScreenState>();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>(); // Key for Drawer
  Map<String, dynamic>? _accountInfo;

  late final List<Widget> _screens;

  @override
  void initState() {
    super.initState();
    _loadAccountInfo();
    _screens = [
      QuotesScreen(onMenuTap: _openDrawer),
      ChartScreen(key: _chartKey, onMenuTap: _openDrawer),
      TradeScreen(onSymbolSelected: _navigateToChart, onMenuTap: _openDrawer),
      HistoryScreen(onMenuTap: _openDrawer),
    ];
  }

  void _openDrawer() {
     _scaffoldKey.currentState?.openDrawer();
  }

  Future<void> _loadAccountInfo() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final String? jsonString = prefs.getString('saved_accounts');
        if (jsonString != null) {
            final List<dynamic> accounts = jsonDecode(jsonString);
            if (accounts.isNotEmpty) {
                setState(() {
                    _accountInfo = accounts.first as Map<String, dynamic>;
                    if (_accountInfo!['name'] == null) {
                         _accountInfo!['name'] = "Trader"; 
                    }
                });
            }
        }
      } catch (e) {
          print("Error loading account info: $e");
      }
  }

  void _navigateToChart(String symbol) {
    setState(() {
      _currentIndex = 1; // Switch to Chart Tab
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
       _chartKey.currentState?.changeSymbol(symbol);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey, // Assign Key
      drawer: SideMenu(accountInfo: _accountInfo),
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.list),
            label: 'Quotes',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.show_chart),
            label: 'Chart',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.compare_arrows),
            label: 'Trade',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.history),
            label: 'History',
          ),
        ],
      ),
    );
  }
}
