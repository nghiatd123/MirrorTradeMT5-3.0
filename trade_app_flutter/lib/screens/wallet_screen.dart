import 'package:flutter/material.dart';

class WalletScreen extends StatelessWidget {
  final VoidCallback onMenuTap;

  const WalletScreen({super.key, required this.onMenuTap});

  void _showContactDialog(BuildContext context, String action) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E222D),
          title: Text(
            "$action Request",
            style: const TextStyle(color: Colors.white),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.telegram,
                size: 50,
                color: Colors.blue,
              ),
              const SizedBox(height: 16),
              const Text(
                "Please contact our admin to process your request:",
                style: TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const SelectableText( // Copyable text
                "@axtrade_admin",
                style: TextStyle(
                  color: Colors.blue,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("Close"),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.menu),
          onPressed: onMenuTap,
        ),
        title: const Text("Wallet"),
        backgroundColor: const Color(0xFF1E222D),
      ),
      backgroundColor: const Color(0xFF151924),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
               // Icon or Image for visual appeal
               const Icon(
                 Icons.account_balance_wallet,
                 size: 80,
                 color: Colors.white24,
               ),
               const SizedBox(height: 40),
               
               // Deposit Button
               SizedBox(
                 width: double.infinity,
                 height: 50,
                 child: ElevatedButton.icon(
                   icon: const Icon(Icons.add_circle_outline),
                   label: const Text("DEPOSIT"),
                   style: ElevatedButton.styleFrom(
                     backgroundColor: Colors.green, // Deposit usually green
                     foregroundColor: Colors.white,
                     textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                   ),
                   onPressed: () => _showContactDialog(context, "Deposit"),
                 ),
               ),
               
               const SizedBox(height: 20),
               
               // Withdraw Button
               SizedBox(
                 width: double.infinity,
                 height: 50,
                 child: ElevatedButton.icon(
                   icon: const Icon(Icons.remove_circle_outline),
                   label: const Text("WITHDRAW"),
                   style: ElevatedButton.styleFrom(
                     backgroundColor: Colors.redAccent, // Withdraw usually red
                     foregroundColor: Colors.white,
                     textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                   ),
                   onPressed: () => _showContactDialog(context, "Withdraw"),
                 ),
               ),
            ],
          ),
        ),
      ),
    );
  }
}
