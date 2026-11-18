import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../config/app_config.dart';
import '../services/web_bridge.dart';
import '../utils/app_colors.dart';
import 'auth_screen.dart';
import 'home_screen.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeIn;
  late Animation<Offset> _slideUp;
  late final TapGestureRecognizer _termsTap;
  late final TapGestureRecognizer _privacyTap;

  @override
  void initState() {
    super.initState();
    _termsTap = TapGestureRecognizer()
      ..onTap = () => WebBridge.openPublic(context, AppConfig.termsPath);
    _privacyTap = TapGestureRecognizer()
      ..onTap = () => WebBridge.openPublic(context, AppConfig.privacyPath);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ));

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );

    _fadeIn = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.3, 1.0, curve: Curves.easeOut),
    );

    _slideUp = Tween<Offset>(
      begin: const Offset(0, 0.18),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.3, 1.0, curve: Curves.easeOutCubic),
    ));

    _controller.forward();
  }

  @override
  void dispose() {
    _termsTap.dispose();
    _privacyTap.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppColors.watch(context);
    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: AppColors.background,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          // Hero image
          Positioned.fill(
            child: Image.asset(
              'assets/images/hero_model.webp',
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
            ),
          ),

          // Vertical fade-to-background gradient
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.0, 0.38, 0.62, 1.0],
                  colors: [
                    Colors.transparent,
                    AppColors.background.withValues(alpha: 0.10),
                    AppColors.background.withValues(alpha: 0.72),
                    AppColors.background,
                  ],
                ),
              ),
            ),
          ),

          // Side vignette
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    AppColors.background.withValues(alpha: 0.18),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),

          // Brand accent
          Positioned(
            top: size.height * 0.07,
            right: 28,
            child: const _WelcomeBrandMark(),
          ),

          // Bottom content
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: FadeTransition(
              opacity: _fadeIn,
              child: SlideTransition(
                position: _slideUp,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    28,
                    0,
                    28,
                    MediaQuery.of(context).padding.bottom + 36,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Headline
                      Text(
                        'Discover Your\nPerfect Look',
                        style: TextStyle(
                          fontSize: 40,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textMain,
                          height: 1.15,
                          letterSpacing: -0.5,
                        ),
                      ),

                      const SizedBox(height: 14),

                      // Subtext
                      Text(
                        'Live camera try-on, foundation shade match, saved looks, and the shop on the website.',
                        style: TextStyle(
                          fontSize: 15,
                          color: AppColors.textMuted,
                          height: 1.6,
                          letterSpacing: 0.1,
                        ),
                      ),

                      const SizedBox(height: 36),

                      // Primary CTA
                      _PrimaryButton(
                        label: 'Get Started',
                        icon: Icons.arrow_forward_rounded,
                        onPressed: () {
                          Navigator.pushReplacement(
                            context,
                            _fadeRoute(const HomeScreen()),
                          );
                        },
                      ),

                      const SizedBox(height: 14),

                      // Secondary CTA
                      _SecondaryButton(
                        label: 'Sign In',
                        onPressed: () {
                          Navigator.push(
                            context,
                            _fadeRoute(
                                const AuthScreen(openHomeOnSuccess: true)),
                          );
                        },
                      ),

                      const SizedBox(height: 20),

                      // Legal note
                      Center(
                        child: Text.rich(
                          TextSpan(
                            style: TextStyle(
                              fontSize: 11.5,
                              color: AppColors.textMuted.withValues(alpha: 0.6),
                            ),
                            children: [
                              const TextSpan(
                                text: 'By continuing you agree to our ',
                              ),
                              TextSpan(
                                text: 'Terms',
                                style: TextStyle(
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.w600,
                                  decoration: TextDecoration.underline,
                                ),
                                recognizer: _termsTap,
                              ),
                              const TextSpan(text: ' & '),
                              TextSpan(
                                text: 'Privacy Policy',
                                style: TextStyle(
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.w600,
                                  decoration: TextDecoration.underline,
                                ),
                                recognizer: _privacyTap,
                              ),
                            ],
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  PageRoute _fadeRoute(Widget page) => PageRouteBuilder(
        pageBuilder: (_, __, ___) => page,
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 400),
      );
}

// ── Primary Button ─────────────────────────────────────────────────────────

class _PrimaryButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  const _PrimaryButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  @override
  State<_PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<_PrimaryButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onPressed();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          width: double.infinity,
          height: 58,
          decoration: BoxDecoration(
            // Fixed gradient — avoids fragile color channel arithmetic
            gradient: LinearGradient(
              colors: [
                AppColors.primary,
                const Color(0xFFD4748E),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withValues(alpha: 0.42),
                blurRadius: 22,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                widget.label,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(width: 10),
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(widget.icon, color: Colors.white, size: 18),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Secondary Button ──────────────────────────────────────────────────────

class _SecondaryButton extends StatefulWidget {
  final String label;
  final VoidCallback onPressed;

  const _SecondaryButton({
    required this.label,
    required this.onPressed,
  });

  @override
  State<_SecondaryButton> createState() => _SecondaryButtonState();
}

class _SecondaryButtonState extends State<_SecondaryButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onPressed();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          width: double.infinity,
          height: 58,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: AppColors.border.withValues(alpha: 0.6),
              width: 1.4,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Center(
            child: Text(
              widget.label,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: AppColors.primary,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Welcome brand mark ──────────────────────────────────────────────────────────

class _WelcomeBrandMark extends StatefulWidget {
  const _WelcomeBrandMark();

  @override
  State<_WelcomeBrandMark> createState() => _WelcomeBrandMarkState();
}

class _WelcomeBrandMarkState extends State<_WelcomeBrandMark>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  late Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);
    _pulse = Tween<double>(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(parent: _c, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _pulse,
      child: Image.asset(
        'assets/images/oval_face_ivory.png',
        height: 22,
        width: 22,
        fit: BoxFit.contain,
        semanticLabel: 'AR Makeup Try-On',
      ),
    );
  }
}