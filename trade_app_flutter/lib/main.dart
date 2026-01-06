import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/chart_screen.dart';
import 'screens/trade_screen.dart';
import 'screens/quotes_screen.dart';
import 'screens/login_screen.dart';
import 'screens/wallet_screen.dart'; // Import Wallet Screen
import 'screens/history_screen.dart';
import 'widgets/side_menu.dart';

import 'package:http/http.dart' as http;
import 'api_config.dart';

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
      debugShowCheckedModeBanner: false,
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
  }

  void _initScreens() {
      String loginId = "";
      if (_accountInfo != null) {
          loginId = _accountInfo!['login'].toString();
      }

      _screens = [
        QuotesScreen(onMenuTap: _openDrawer),
        ChartScreen(key: _chartKey, onMenuTap: _openDrawer, login: loginId),
        TradeScreen(onSymbolSelected: _navigateToChart, onMenuTap: _openDrawer, login: loginId),
        HistoryScreen(onMenuTap: _openDrawer, login: loginId),
        WalletScreen(onMenuTap: _openDrawer), // New Wallet Tab
      ];
  }

  void _openDrawer() {
     _scaffoldKey.currentState?.openDrawer();
  }

  Future<void> _loadAccountInfo() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final String? jsonString = prefs.getString('saved_accounts');
        bool found = false;

        if (jsonString != null) {
            final List<dynamic> accounts = jsonDecode(jsonString);
            if (accounts.isNotEmpty) {
                found = true;
                setState(() {
                    _accountInfo = accounts.first as Map<String, dynamic>;
                    if (_accountInfo!['name'] == null) {
                         _accountInfo!['name'] = "Trader"; 
                    }
                    _initScreens();
                });
                
                // Wake up backend worker
                if (_accountInfo != null && _accountInfo!['login'] != null) {
                   String loginId = _accountInfo!['login'].toString();
                   if (loginId.isNotEmpty) _wakeUpBackend(loginId);
                }
            }
        }

        if (!found) {
             print("No saved accounts found, redirecting to login.");
             // Force logout and go to login screen
             await prefs.setBool('is_logged_in', false);
             if (mounted) {
                 Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (_) => const LoginScreen())
                 );
             }
        }
      } catch (e) {
          print("Error loading account info: $e");
          // Safety fallback
           if (mounted) {
             final prefs = await SharedPreferences.getInstance();
             await prefs.setBool('is_logged_in', false);
             Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const LoginScreen())
             );
           }
      }
  }

  Future<void> _wakeUpBackend(String login) async {
       // Fire and forget request to trigger auto-start in backend
       try {
           final url = Uri.parse('${ApiConfig.baseUrl}/positions?login=$login');
           print("Waking up backend logic for $login...");
           
           // Silent wake-up (no "Connecting..." snackbar)

           // Short timeout because we just want to hit the server
           await http.get(url).timeout(const Duration(seconds: 3)).then((resp) {
               if (mounted) {
                   if (resp.statusCode == 200 || resp.statusCode == 404) {
                       // Success - do nothing (silent)
                       print("Backend woke up successfully");
                   } else {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Server Error: ${resp.statusCode}"), backgroundColor: Colors.orange, duration: const Duration(seconds: 2)));
                   }
               }
           }); 
       } catch (e) {
           print("Wake up error (ignored): $e");
           // Suppress error UI because this is just a background trigger.
           // If the backend fails, the actual screens (Quotes/Trade) will show their own connection status.
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
      body: _accountInfo == null 
        ? const Center(child: CircularProgressIndicator())
        : IndexedStack(
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
          BottomNavigationBarItem(
            icon: Icon(Icons.account_balance_wallet),
            label: 'Wallet',
          ),
        ],
      ),
    );
  }
}
