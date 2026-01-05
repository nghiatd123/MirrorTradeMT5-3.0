import 'package:flutter/material.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _selectedLanguage = 'English'; 

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF151924),
      appBar: AppBar(
        title: const Text("Settings", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF1E222D),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListView(
        children: [
          _buildSectionHeader("LANGUAGE"),
          _buildLanguageOption("English", "en"),
          
          _buildSectionHeader("OTHER"),
          ListTile(
            title: const Text("Version", style: TextStyle(color: Colors.white)),
            subtitle: const Text("1.0.0 (Build 102)", style: TextStyle(color: Colors.grey)),
            leading: const Icon(Icons.info_outline, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        title,
        style: const TextStyle(
          color: Colors.blue,
          fontWeight: FontWeight.bold,
          fontSize: 13,
        ),
      ),
    );
  }

  Widget _buildLanguageOption(String label, String code) {
    final bool isSelected = (code == 'en'); // Force English selected
                            
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1E222D),
        border: Border(bottom: BorderSide(color: Colors.white10, width: 0.5)),
      ),
      child: ListTile(
        title: Text(label, style: const TextStyle(color: Colors.white, fontSize: 16)),
        trailing: isSelected ? const Icon(Icons.check, color: Colors.blue) : null,
        onTap: () {
          setState(() {
            _selectedLanguage = 'English';
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Language set to $label"))
          );
        },
      ),
    );
  }
}
