import 'package:flutter/material.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: const [
          ListTile(
            leading: Icon(Icons.privacy_tip),
            title: Text('Privacy & Permissions'),
          ),
          ListTile(
            leading: Icon(Icons.description),
            title: Text('Terms & Disclaimer'),
          ),
          ListTile(leading: Icon(Icons.info), title: Text('App Information')),
        ],
      ),
    );
  }
}
