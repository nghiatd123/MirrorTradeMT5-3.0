import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart'; // Import for MainScreen
import '../api_config.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _loginCtrl = TextEditingController();
  final TextEditingController _passCtrl = TextEditingController();
  final TextEditingController _serverCtrl = TextEditingController();
  bool _isLoading = false;
  List<Map<String, dynamic>> _savedAccounts = [];

  @override
  void initState() {
    super.initState();
    _loadSavedAccounts();
  }

  Future<void> _loadSavedAccounts() async {
    final prefs = await SharedPreferences.getInstance();
    final String? jsonString = prefs.getString('saved_accounts');
    
    if (jsonString != null) {
      setState(() {
         _savedAccounts = List<Map<String, dynamic>>.from(jsonDecode(jsonString));
      });
      // Auto-fill the most recent account
      if (_savedAccounts.isNotEmpty) {
          final last = _savedAccounts.first;
          _loginCtrl.text = last['login'] ?? '';
          _passCtrl.text = last['password'] ?? '';
          _serverCtrl.text = last['server'] ?? '';
      }
    } else {
        // Migration from legacy single-account storage
        final legacyLogin = prefs.getString('mt5_login');
        if (legacyLogin != null) {
            final acc = {
                'login': legacyLogin,
                'password': prefs.getString('mt5_password') ?? '',
                'server': prefs.getString('mt5_server') ?? ''
            };
            setState(() {
                _savedAccounts.add(acc);
                _loginCtrl.text = legacyLogin; // Auto-fill
                _passCtrl.text = acc['password']!;
                _serverCtrl.text = acc['server']!;
            });
            _saveAccounts(); 
        }
    }
  }

  Future<void> _saveAccounts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_accounts', jsonEncode(_savedAccounts));
  }
  
  void _addOrUpdateAccount(String login, String password, String server) {
      final index = _savedAccounts.indexWhere((acc) => acc['login'] == login && acc['server'] == server);
      final newAcc = {'login': login, 'password': password, 'server': server};
      
      setState(() {
          if (index != -1) {
              _savedAccounts.removeAt(index);
          }
          _savedAccounts.insert(0, newAcc);
      });
      _saveAccounts();
  }

  void _removeAccount(int index) {
      setState(() {
          _savedAccounts.removeAt(index);
      });
      _saveAccounts();
  }

  Future<void> _login() async {
    setState(() => _isLoading = true);

    final String login = _loginCtrl.text.trim();
    final String password = _passCtrl.text.trim();
    final String server = _serverCtrl.text.trim();

    if (login.isEmpty || password.isEmpty || server.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Please fill all fields"), backgroundColor: Colors.red));
      setState(() => _isLoading = false);
      return;
    }

    try {
      final url = Uri.parse('${ApiConfig.baseUrl}/login');
      print("Attempting to connect to: $url");
      
      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "login": login,
          "password": password,
          "server": server
        })

      );

      print("Response Code: ${response.statusCode}");
      print("Response Body: ${response.body}");

      if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data['status'] == 'success') {
            _addOrUpdateAccount(login, password, server);
            
            // Save Auto-Login flag
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('is_logged_in', true);

            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Login Successful!"), backgroundColor: Colors.green));
            
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(builder: (_) => const MainScreen()),
              (route) => false
            );
          } else {
             if (!mounted) return;
             ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Login Failed: ${data['detail'] ?? 'Unknown error'}"), backgroundColor: Colors.red));
          }
      } else {
          // Non-200 Status
          if (!mounted) return;
          String errorMsg = "Server Error (${response.statusCode})";
          try {
             // Try to parse if it's JSON error
             final errData = jsonDecode(response.body);
             if (errData['detail'] != null) errorMsg += ": ${errData['detail']}";
          } catch (_) {
             // Likely HTML (Cloudflare or Nginx error)
             if (response.body.contains("<!DOCTYPE html>")) {
                 errorMsg += ": HTML Response (Check Cloudflare/Proxy)";
             } else {
                 errorMsg += ": ${response.body.substring(0, min(100, response.body.length))}...";
             }
          }
           ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorMsg), backgroundColor: Colors.red, duration: const Duration(seconds: 5)));
      }

    } catch (e) {
      if (!mounted) return;
      print("Network Error: $e");
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Network Error: $e"), backgroundColor: Colors.red, duration: const Duration(seconds: 5)));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  int min(int a, int b) => a < b ? a : b;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF151924),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
               const Icon(Icons.candlestick_chart, size: 80, color: Colors.blue),
               const SizedBox(height: 20),
               const Text("ATrade-Connect", style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white)),
               const SizedBox(height: 40),

               TextField(
                 controller: _loginCtrl,
                 keyboardType: TextInputType.text,
                 style: const TextStyle(color: Colors.white),
                 decoration: _inputDeco("Login ID", Icons.person),
               ),

               const SizedBox(height: 16),
               TextField(
                 controller: _passCtrl,
                 obscureText: true,
                 style: const TextStyle(color: Colors.white),
                 decoration: _inputDeco("Password", Icons.lock),
               ),
               const SizedBox(height: 16),
               TextField(
                 controller: _serverCtrl,
                 style: const TextStyle(color: Colors.white),
                 decoration: _inputDeco("Server", Icons.dns),
               ),
               const SizedBox(height: 32),

               SizedBox(
                 width: double.infinity,
                 height: 50,
                 child: ElevatedButton(
                   style: ElevatedButton.styleFrom(
                     backgroundColor: Colors.blue,
                     shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))
                   ),
                   onPressed: _isLoading ? null : _login,
                   child: _isLoading 
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text("Connect", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                 ),
               ),
               
               const SizedBox(height: 40),
               if (_savedAccounts.isNotEmpty) ...[
                 const Align(alignment: Alignment.centerLeft, child: Text("Saved Accounts", style: TextStyle(color: Colors.white54, fontSize: 14))),
                 const SizedBox(height: 10),
                 ..._savedAccounts.asMap().entries.map((entry) {
                    final index = entry.key;
                    final acc = entry.value;
                    final isFirst = index == 0;
                    return Dismissible(
                      key: ValueKey("${acc['login']}_${acc['server']}"),
                      direction: DismissDirection.endToStart,
                      onDismissed: (_) => _removeAccount(index),
                      background: Container(color: Colors.red, alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 20), child: const Icon(Icons.delete, color: Colors.white)),
                      child: Card(
                        color: const Color(0xFF1E222D),
                        shape: RoundedRectangleBorder(
                             borderRadius: BorderRadius.circular(12),
                             side: isFirst ? const BorderSide(color: Colors.green, width: 1.5) : BorderSide.none
                        ),
                        child: ListTile(
                          title: Text("${acc['login']}", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                          subtitle: Text("${acc['server']}", style: const TextStyle(color: Colors.grey, fontSize: 12)),
                          trailing: isFirst 
                             ? const Icon(Icons.check_circle, color: Colors.green)
                             : const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.blue),
                          onTap: () {
                             setState(() {
                               _loginCtrl.text = acc['login'] ?? '';
                               _passCtrl.text = acc['password'] ?? '';
                               _serverCtrl.text = acc['server'] ?? '';
                             });
                             _login(); // Quick Connect
                          },
                        ),
                      ),
                    );
                 }).toList(),
               ]
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDeco(String label, IconData icon) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white54),
      prefixIcon: Icon(icon, color: Colors.white54),
      filled: true,
      fillColor: const Color(0xFF1E222D),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.blue)
      )
    );
  }
}
