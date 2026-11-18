import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../utils/app_colors.dart';
import '../widgets/app_loader.dart';
import 'home_screen.dart';
import 'try_on_screen.dart';
import 'welcome_screen.dart';

class CameraPermissionScreen extends StatefulWidget {
  const CameraPermissionScreen({
    super.key,
    this.returnGrantedToCaller = false,
    this.isSignedIn,
  });

  static const _confirmedSessionKey = 'camera_confirmed_auth_session';

  static String? _sessionId() {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null) return null;
    final payload = token.split('.')[1];
    final claims = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(payload))));
    return claims['session_id'] as String?;
  }

  static Future<bool> allowFeature(BuildContext context, {
    required bool deviceGranted,
    bool guestForTest = false,
  }) async {
    final sessionId = guestForTest ? null : _sessionId();
    final prefs = sessionId == null ? null : await SharedPreferences.getInstance();
    if (!context.mounted) return false;
    if (deviceGranted &&
        (sessionId == null || prefs?.getString(_confirmedSessionKey) == sessionId)) {
      return true;
    }
    final allowed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => const CameraPermissionScreen(returnGrantedToCaller: true),
    ));
    if (allowed != true || !context.mounted) return false;
    if (sessionId != null) {
      if (_sessionId() != sessionId) return false;
      await prefs!.setString(_confirmedSessionKey, sessionId);
    }
    return true;
  }

  /// Home asks for the camera and then opens try-on itself, so a grant
  /// pops back instead of pushing a second camera onto the overlay.
  final bool returnGrantedToCaller;

  /// Widget tests pass this so Maybe later does not touch Supabase.
  @visibleForTesting
  final bool Function()? isSignedIn;

  @override
  State<CameraPermissionScreen> createState() =>
      _CameraPermissionScreenState();
}

class _CameraPermissionScreenState extends State<CameraPermissionScreen>
    with SingleTickerProviderStateMixin {
  bool _isRequesting = false;

  late final AnimationController _animController;
  late final Animation<double> _fadeAnim;
  late final Animation<Offset> _slideAnim;
  late final Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _fadeAnim =
        CurvedAnimation(parent: _animController, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.07),
      end: Offset.zero,
    ).animate(
        CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic));
    _scaleAnim = Tween<double>(begin: 0.88, end: 1.0).animate(
        CurvedAnimation(parent: _animController, curve: Curves.easeOutBack));
    _animController.forward();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  Future<void> requestCameraPermission() async {
    setState(() => _isRequesting = true);
    final current = await Permission.camera.status;
    final status = current.isGranted ? current : await Permission.camera.request();
    if (!mounted) return;
    setState(() => _isRequesting = false);

    if (status.isGranted) {
      final navigator = Navigator.of(context);
      if (widget.returnGrantedToCaller && navigator.canPop()) {
        navigator.pop(true);
        return;
      }
      navigator.pushReplacement(
        MaterialPageRoute(builder: (_) => const TryOnScreen()),
      );
    } else if (status.isPermanentlyDenied) {
      _showSnackBar(
        'Camera permission is permanently denied.',
        action: SnackBarAction(
          label: 'Open Settings',
          textColor: AppColors.primary,
          onPressed: openAppSettings,
        ),
      );
    } else {
      _showSnackBar('Camera access is required for AR Try-On.');
    }
  }

  void _showSnackBar(String message, {SnackBarAction? action}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: action,
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  void _maybeLater() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
      return;
    }
    final signedIn = widget.isSignedIn?.call() ?? _sessionSignedIn();
    navigator.pushReplacement(
      MaterialPageRoute(
        builder: (_) =>
            signedIn ? const HomeScreen() : const WelcomeScreen(),
      ),
    );
  }

  bool _sessionSignedIn() {
    try {
      return Supabase.instance.client.auth.currentSession != null;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    AppColors.watch(context);
    // ── Screen dimensions ke hisaab se responsive ──────────────────────
    final screenH = MediaQuery.of(context).size.height;
    final isSmallScreen = screenH < 700;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 28,
            vertical: isSmallScreen ? 12 : 24,
          ),
          child: FadeTransition(
            opacity: _fadeAnim,
            child: SlideTransition(
              position: _slideAnim,
              child: Column(
                children: [
                  // ── Main content ─────────────────────────────────────
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(height: isSmallScreen ? 16 : 32),

                          // Animated icon
                          ScaleTransition(
                            scale: _scaleAnim,
                            child: _buildIconDisplay(),
                          ),

                          SizedBox(height: isSmallScreen ? 28 : 44),

                          Text(
                            'Allow Camera\nAccess',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: isSmallScreen ? 28 : 32,
                              fontWeight: FontWeight.w800,
                              color: AppColors.textMain,
                              height: 1.2,
                              letterSpacing: -0.5,
                            ),
                          ),

                          SizedBox(height: isSmallScreen ? 12 : 16),

                          Text(
                            'To apply virtual makeup in real-time, we need access to your camera. Try-on camera video stays on this phone and is not uploaded.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 15,
                              color: AppColors.textMuted,
                              height: 1.6,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'Face a window so the makeup can sit on your face.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 15,
                              color: AppColors.textMuted,
                              height: 1.6,
                            ),
                          ),

                          SizedBox(height: isSmallScreen ? 24 : 36),

                          // Feature highlights — app ke actual features
                          _buildFeatureRow(
                            icon: Icons.face_retouching_natural_outlined,
                            label: 'Real-time AR makeup try-on',
                          ),
                          const SizedBox(height: 12),
                          _buildFeatureRow(
                            icon: Icons.shield_outlined,
                            label: 'Try-on camera video stays on this phone',
                          ),
                          const SizedBox(height: 12),
                          _buildFeatureRow(
                            icon: Icons.bookmark_outline_rounded,
                            label: 'Save & revisit your favourite looks',
                          ),

                          SizedBox(height: isSmallScreen ? 16 : 24),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Keep the actions separated from the scrollable content.
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: ElevatedButton(
                          onPressed: _isRequesting
                              ? null
                              : requestCameraPermission,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            disabledBackgroundColor:
                                AppColors.primary.withAlpha(120),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            elevation: 0,
                          ),
                          child: _isRequesting
                              ? const AppLoader.inline(
                                  size: 22,
                                  color: Colors.white,
                                  strokeWidth: 2.5,
                                )
                              : Text(
                                  'Allow Camera',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                    letterSpacing: 0.02,
                                  ),
                                ),
                        ),
                      ),

                      const SizedBox(height: 8),

                      TextButton(
                        onPressed: _isRequesting ? null : _maybeLater,
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.textMuted,
                          minimumSize: const Size(48, 48),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24, vertical: 12),
                        ),
                        child: const Text(
                          'Maybe later',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),

                      const SizedBox(height: 8),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIconDisplay() {
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 148, height: 148,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.primary.withAlpha(12),
          ),
        ),
        Container(
          width: 124, height: 124,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.primary.withAlpha(20),
          ),
        ),
        Container(
          width: 100, height: 100,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.primary.withAlpha(30),
            border: Border.all(
              color: AppColors.primary.withAlpha(60),
              width: 1.5,
            ),
          ),
          child: Icon(
            Icons.camera_alt_outlined,
            size: 46,
            color: AppColors.primary,
          ),
        ),
      ],
    );
  }

  Widget _buildFeatureRow({
    required IconData icon,
    required String label,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: AppColors.primary, size: 18),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppColors.textMain,
              ),
            ),
          ),
          const Icon(
            Icons.check_circle_rounded,
            color: Color(0xFF22C55E),
            size: 18,
          ),
        ],
      ),
    );
  }
}
