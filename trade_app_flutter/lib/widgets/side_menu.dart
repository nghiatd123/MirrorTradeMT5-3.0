import 'package:flutter/material.dart';
import '../screens/login_screen.dart';
import '../screens/settings_screen.dart';

class SideMenu extends StatelessWidget {
  final Map<String, dynamic>? accountInfo;
  
  const SideMenu({super.key, this.accountInfo});

  @override
  Widget build(BuildContext context) {
    // Default values if no info
    final String name = accountInfo?['name'] ?? "Trader";
    final String login = accountInfo?['login']?.toString() ?? "Login ID";
    final String server = accountInfo?['server'] ?? "Server";
    final bool isDemo = server.toLowerCase().contains('demo') || server.toLowerCase().contains('trial');

    return Drawer(
      backgroundColor: const Color(0xFF151924),
      child: Column(
        children: [
          // === HEADER ===
          Container(
            padding: const EdgeInsets.fromLTRB(16, 50, 16, 20),
            decoration: const BoxDecoration(
              color: Color(0xFF1E222D),
              border: Border(bottom: BorderSide(color: Colors.white10)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Avatar / Logo
                    Container(
                      width: 50, height: 50,
                      decoration: BoxDecoration(
                        color: Colors.yellow[700],
                        borderRadius: BorderRadius.circular(4),
                      ),
                      alignment: Alignment.center,
                      child: const Text("Ex", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 18)),
                    ),
                    const SizedBox(width: 16),
                    // Info
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 4),
                          Text("$login - $server", style: const TextStyle(color: Colors.grey, fontSize: 13), overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 8),
                          GestureDetector(
                            onTap: () {
                              Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginScreen()));
                            },
                            child: const Text("Manage Accounts", style: TextStyle(color: Colors.blue, fontSize: 14, fontWeight: FontWeight.bold)),
                          )
                        ],
                      ),
                    ),
                    // Ribbon (Demo/Real)
                    if (isDemo)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: const BoxDecoration(
                        color: Colors.green,
                        borderRadius: BorderRadius.only(topLeft: Radius.circular(4), bottomRight: Radius.circular(4))
                      ),
                      child: const Text("Real", style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                    )
                  ],
                ),
              ],
            ),
          ),
          
          // === MENU ITEMS ===
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                _buildMenuItem(context, Icons.show_chart, "Trade", isActive: true, onTap: () => Navigator.pop(context)),
                _buildMenuItem(context, Icons.newspaper, "News"),
                _buildMenuItem(context, Icons.mail_outline, "Mailbox", badgeCount: 31),
                _buildMenuItem(context, Icons.article_outlined, "Journal"),
                _buildMenuItem(context, Icons.settings_outlined, "Settings", onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen()));
                }),
                const Divider(color: Colors.white10),
                _buildMenuItem(context, Icons.calendar_month_outlined, "Economic Calendar", isAd: true),
                _buildMenuItem(context, Icons.people_outline, "Traders Community"),
                _buildMenuItem(context, Icons.send_outlined, "MQL5 Algo Trading"),
                const Divider(color: Colors.white10),
                _buildMenuItem(context, Icons.help_outline, "User Guide"),
                _buildMenuItem(context, Icons.info_outline, "About Us", onTap: () {
                    Navigator.pop(context);
                    showAboutDialog(
                        context: context,
                        applicationName: "MirrorTrade MT5",
                        applicationVersion: "1.0.0",
                        applicationIcon: Container(
                            width: 50, height: 50,
                            color: Colors.yellow[700],
                            alignment: Alignment.center,
                            child: const Text("Ex", style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                        children: const [
                            Text("MT5 Trading Simulation App."),
                            SizedBox(height: 10),
                            Text("Beta Version."),
                        ]
                    );
                }),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildMenuItem(BuildContext context, IconData icon, String title, {bool isActive = false, int badgeCount = 0, bool isAd = false, VoidCallback? onTap}) {
    return ListTile(
      leading: Icon(icon, color: isActive ? Colors.white : Colors.grey[400]),
      title: Text(title, style: TextStyle(color: isActive ? Colors.white : Colors.grey[300], fontWeight: isActive ? FontWeight.bold : FontWeight.normal)),
      tileColor: isActive ? const Color(0xFF2A2E39) : null,
      onTap: onTap ?? () {
        Navigator.pop(context); // Close drawer
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$title - Coming Soon")));
      },
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isAd)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(border: Border.all(color: Colors.blue), borderRadius: BorderRadius.circular(4)),
              child: const Text("Ads", style: TextStyle(color: Colors.blue, fontSize: 9)),
            ),
          if (badgeCount > 0)
            Container(
               padding: const EdgeInsets.all(6),
               decoration: const BoxDecoration(color: Colors.orange, shape: BoxShape.circle),
               child: Text("$badgeCount", style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
            )
        ],
      ),
    );
  }
}
