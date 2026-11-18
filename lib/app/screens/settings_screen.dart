import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';
import '../services/web_bridge.dart';
import '../utils/app_colors.dart';
import 'notifications_inbox_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _isDarkMode = false;
  bool _cameraOn = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadCamera();
  }

  Future<void> _loadCamera() async {
    final status = await Permission.camera.status;
    if (mounted) setState(() => _cameraOn = status.isGranted);
  }

  Future<void> _toggleCamera(bool value) async {
    if (value) {
      final status = await Permission.camera.request();
      if (mounted) setState(() => _cameraOn = status.isGranted);
      return;
    }
    await openAppSettings();
    final status = await Permission.camera.status;
    if (mounted) setState(() => _cameraOn = status.isGranted);
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _isDarkMode = prefs.getBool('is_dark_mode') ?? false;
        AppColors.themeNotifier.value =
            _isDarkMode ? ThemeMode.dark : ThemeMode.light;
      });
    }
  }

  Future<void> _saveSetting(String key, dynamic value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value is bool) {
      await prefs.setBool(key, value);
    } else if (value is String) {
      await prefs.setString(key, value);
    }
  }

  /// The help centre is a public page — no session is handed over, so this URL
  /// stays safe to share. [WebBridge] reports its own failures.
  Future<void> _launchHelpCenter() =>
      WebBridge.openPublic(context, AppConfig.supportPath);

  void _openNotifications() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const NotificationsInboxScreen(),
      ),
    );
  }

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.auto_awesome,
                color: AppColors.primary,
                size: 36,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'AR Makeup',
              style: TextStyle(
                color: AppColors.textMain,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Version 1.0.0',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Live makeup try-on, foundation shade match, saved looks, and the shop on the website.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '© 2026 AR Makeup',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 12,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Close',
              style: TextStyle(
                color: AppColors.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppColors.themeNotifier,
      builder: (context, ThemeMode currentMode, child) {
        AppColors.watch(context);
        return Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppBar(
            backgroundColor: AppColors.background,
            elevation: 0,
            iconTheme: IconThemeData(color: AppColors.textMain),
            title: Text(
              'Settings',
              style: TextStyle(
                  color: AppColors.textMain, fontWeight: FontWeight.w600),
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              // ── Preferences ──────────────────────────────────────────
              Text(
                'PREFERENCES',
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.02),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    ListTile(
                      leading: Icon(
                        _isDarkMode
                            ? Icons.dark_mode
                            : Icons.light_mode_outlined,
                        color: AppColors.textMain,
                      ),
                      title: Text(
                        'Dark Theme',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: AppColors.textMain,
                        ),
                      ),
                      subtitle: Text(
                        _isDarkMode ? 'Dark mode is on' : 'Light mode is on',
                        style: TextStyle(
                            fontSize: 12, color: AppColors.textMuted),
                      ),
                      trailing: Switch(
                        value: _isDarkMode,
                        activeColor: AppColors.primary,
                        onChanged: (val) {
                          AppColors.themeNotifier.value =
                              val ? ThemeMode.dark : ThemeMode.light;
                          setState(() => _isDarkMode = val);
                          _saveSetting('is_dark_mode', val);
                        },
                      ),
                    ),
                    Divider(height: 1, color: AppColors.border),
                    ListTile(
                      leading: Icon(
                        Icons.camera_alt_outlined,
                        color: AppColors.textMain,
                      ),
                      title: Text(
                        'Camera access',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: AppColors.textMain,
                        ),
                      ),
                      subtitle: Text(
                        _cameraOn ? 'Camera is on' : 'Camera is off',
                        style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                      ),
                      trailing: Switch(
                        value: _cameraOn,
                        activeThumbColor: AppColors.primary,
                        onChanged: _toggleCamera,
                      ),
                    ),
                    Divider(height: 1, color: AppColors.border),
                    _buildInteractiveTile(
                      Icons.notifications_outlined,
                      'Notifications',
                      'Orders and back-in-stock',
                      _openNotifications,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 32),

              // ── Support & About ───────────────────────────────────────
              Text(
                'SUPPORT & ABOUT',
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.02),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    _buildInteractiveTile(
                      Icons.help_outline,
                      'Help Center',
                      'FAQs & contact support',
                      _launchHelpCenter,
                    ),
                    Divider(height: 1, color: AppColors.border),
                    _buildInteractiveTile(
                      Icons.info_outline,
                      'About',
                      'Version 1.0.0',
                      _showAboutDialog,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 40),
            ],
          ),
        );
      },
    );
  }

  Widget _buildInteractiveTile(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) {
    return ListTile(
      leading: Icon(icon, color: AppColors.textMain),
      title: Text(
        title,
        style: TextStyle(
            fontWeight: FontWeight.w600, color: AppColors.textMain),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 12, color: AppColors.textMuted),
      ),
      trailing: Icon(Icons.chevron_right, color: AppColors.textMuted),
      onTap: onTap,
    );
  }
}