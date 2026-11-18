import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../cache/looks_cache.dart';
import '../config/app_config.dart';
import '../services/web_bridge.dart';
import '../utils/app_colors.dart';
import '../utils/app_image_cache.dart';
import '../utils/image_url.dart';
import 'auth_screen.dart';
import 'camera_permission_screen.dart';
import 'favourites_screen.dart';
import 'foundation_match_screen.dart';
import 'makeup_bag_screen.dart';
import 'profile_screen.dart';
import 'saved_looks_screen.dart';
import 'try_on_screen.dart';

/// Front door. The live camera stays on [TryOnScreen]; this screen only links out.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.overCamera = false,
    this.signedInOverride,
    this.greetingNameOverride,
    this.looksOverride,
    this.cameraGrantedOverride,
  });

  final bool overCamera;

  /// Widget tests pass this so the screen can render without Supabase.
  @visibleForTesting
  final bool? signedInOverride;

  /// First name already resolved. Empty means the "Welcome" greeting.
  @visibleForTesting
  final String? greetingNameOverride;

  /// Recent looks already in hand. Skips [LooksCache] when set.
  @visibleForTesting
  final List<Map<String, dynamic>>? looksOverride;

  /// Widget tests pass this so Try on does not touch the permission plugin.
  @visibleForTesting
  final bool? cameraGrantedOverride;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.looksOverride == null) {
      LooksCache.instance.addListener(_onLooks);
    }
  }

  void _onLooks() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    if (widget.looksOverride == null) {
      LooksCache.instance.removeListener(_onLooks);
    }
    super.dispose();
  }

  bool _signedIn() {
    final override = widget.signedInOverride;
    if (override != null) return override;
    try {
      return Supabase.instance.client.auth.currentUser != null;
    } catch (_) {
      return false;
    }
  }

  Future<void> _openAccount(BuildContext context, Widget page) async {
    if (!_signedIn()) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(builder: (_) => const AuthScreen(isLoginMode: true)),
      );
      return;
    }
    if (!context.mounted) return;
    final result = await Navigator.push<Object?>(
      context,
      MaterialPageRoute(builder: (_) => page),
    );
    if (!context.mounted) return;
    _forwardToCamera(context, result);
  }

  void _forwardToCamera(BuildContext context, Object? result) {
    if (!context.mounted || result == null) return;
    final backToCamera =
        result is List ||
        result is FoundationTryOnRequest ||
        result is FoundationLookRequest ||
        result == 'tryOnWithMyBag' ||
        (result is String && result.startsWith('tryOn:'));
    if (backToCamera) _openTryOn(context, result);
  }

  Future<void> _openSkinCheck(BuildContext context) async {
    final continueToSite = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Text(
          'This opens the website skin check. That photo is sent to build a routine and is not a diagnosis. The try-on camera photo stays on this phone and is not uploaded.',
          style: TextStyle(
            color: AppColors.textMain,
            fontSize: 14,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('Cancel', style: TextStyle(color: AppColors.textMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              'Continue',
              style: TextStyle(
                color: AppColors.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    if (continueToSite == true && context.mounted) {
      await WebBridge.openAuthenticated(context, AppConfig.skinAnalysisPath);
    }
  }

  bool _openingCamera = false;

  Future<void> _openTryOn(BuildContext context, [Object? request]) async {
    if (_openingCamera) return;
    _openingCamera = true;
    try {
      final granted = await _cameraGranted();
      if (!context.mounted) return;
      if (!await CameraPermissionScreen.allowFeature(context,
        deviceGranted: granted, guestForTest: widget.signedInOverride != null,
      )) return;
      if (!context.mounted) return;
      final navigator = Navigator.of(context);
      if (widget.overCamera) {
        navigator.pop(request);
      } else {
        await navigator.push(MaterialPageRoute(
          builder: (_) => TryOnScreen(initialRequest: request),
        ));
      }
    } finally {
      _openingCamera = false;
    }
  }

  Future<bool> _cameraGranted() async {
    final override = widget.cameraGrantedOverride;
    if (override != null) return override;
    try {
      final status = await Permission.camera.status;
      return status.isGranted;
    } catch (_) {
      return false;
    }
  }

  Future<void> _openProfile(BuildContext context) async {
    if (!_signedIn()) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(builder: (_) => const AuthScreen(isLoginMode: true)),
      );
      return;
    }
    if (!context.mounted) return;
    final result = await Navigator.push<Object?>(
      context,
      MaterialPageRoute(builder: (_) => const ProfileScreen()),
    );
    if (context.mounted) _forwardToCamera(context, result);
  }

  String _greeting() {
    final override = widget.greetingNameOverride;
    if (override != null) {
      final trimmed = override.trim();
      return trimmed.isEmpty ? 'Welcome' : 'Hi, $trimmed';
    }
    final first = _firstNameFromSession();
    if (first == null || first.isEmpty) return 'Welcome';
    return 'Hi, $first';
  }

  String? _firstNameFromSession() {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return null;
      final meta = user.userMetadata;
      final rawName =
          _metaString(meta, 'full_name') ?? _metaString(meta, 'name');
      if (rawName != null) {
        final token = rawName.trim().split(RegExp(r'\s+')).first;
        final word = token.replaceAll(RegExp(r'[^A-Za-z]'), '');
        if (word.isNotEmpty) return _capitalize(word);
      }
      final email = user.email ?? '';
      final at = email.indexOf('@');
      if (at > 0) {
        final prefix = email.substring(0, at).split(RegExp(r'[._+\d]')).first;
        final word = prefix.replaceAll(RegExp(r'[^A-Za-z]'), '');
        if (word.isNotEmpty) return _capitalize(word);
      }
    } catch (_) {}
    return null;
  }

  String? _avatarUrl() {
    try {
      final meta = Supabase.instance.client.auth.currentUser?.userMetadata;
      final url = _metaString(meta, 'avatar_url');
      if (url == null || url.isEmpty) return null;
      return upgradeImageUrl(url);
    } catch (_) {
      return null;
    }
  }

  String? _metaString(Map<String, dynamic>? meta, String key) {
    final value = meta?[key];
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  String _capitalize(String word) {
    if (word.isEmpty) return word;
    return word[0].toUpperCase() + word.substring(1).toLowerCase();
  }

  List<Map<String, dynamic>> _recentLooks() {
    final source =
        widget.looksOverride ??
        (_signedIn()
            ? LooksCache.instance.looks
            : const <Map<String, dynamic>>[]);
    if (source.length <= 3) {
      return List<Map<String, dynamic>>.from(source);
    }
    return source.sublist(0, 3);
  }

  @override
  Widget build(BuildContext context) {
    AppColors.watch(context);
    final signedIn = _signedIn();
    final heroHeight = (MediaQuery.sizeOf(context).height * 0.42).clamp(
      240.0,
      340.0,
    );
    final tiles = <_HomeTile>[
      _HomeTile(
        icon: Icons.photo_library_outlined,
        label: 'Saved looks',
        onTap: () => _openAccount(context, const SavedLooksScreen()),
      ),
      _HomeTile(
        icon: Icons.favorite_border_rounded,
        label: 'Favourites',
        onTap: () => _openAccount(context, const FavouritesScreen()),
      ),
      _HomeTile(
        icon: Icons.spa_outlined,
        label: 'Skin analysis',
        onTap: () => _openSkinCheck(context),
      ),
      _HomeTile(
        icon: Icons.storefront_outlined,
        label: 'Products',
        onTap: () =>
            WebBridge.openAuthenticated(context, AppConfig.productsPath),
      ),
    ];

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemStatusBarContrastEnforced: false,
      ),
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: Stack(
          children: [
            SafeArea(
              top: false,
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _RiseIn(
                      delay: Duration.zero,
                      child: _Hero(
                        height:
                            heroHeight +
                            MediaQuery.paddingOf(context).top +
                            (MediaQuery.textScalerOf(context).scale(1) - 1)
                                    .clamp(0.0, 3.0) *
                                250,
                        greeting: _greeting(),
                        avatarUrl: _avatarUrl(),
                        onProfile: () => _openProfile(context),
                        onTryOn: () => _openTryOn(context),
                        onFindShade: () async {
                          final result = await Navigator.push<Object?>(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const FoundationMatchScreen(),
                            ),
                          );
                          if (context.mounted)
                            _forwardToCamera(context, result);
                        },
                      ),
                    ),
                    if (!signedIn)
                      _RiseIn(
                        delay: const Duration(milliseconds: 40),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                          child: Text(
                            'Sign in to keep looks, orders, and your bag.',
                            style: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 14,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ),
                    _RiseIn(
                      delay: const Duration(milliseconds: 40),
                      child: const _SectionTitle('Explore', accent: true),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                      child: Material(
                        color: AppColors.isDark
                            ? const Color(0xff392731)
                            : const Color(0xfff3e5e7),
                        elevation: 2,
                        shadowColor: const Color(0x44572c41),
                        borderRadius: BorderRadius.circular(18),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () =>
                              _openAccount(context, const MakeupBagScreen()),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 17,
                            ),
                            child: Row(
                              children: [
                                for (final shades in const [
                                  [
                                    Color(0xfff7d7c7),
                                    Color(0xffdfb59f),
                                    Color(0xffb88c79),
                                  ],
                                  [
                                    Color(0xffdfb5b7),
                                    Color(0xffbd898d),
                                    Color(0xff9c686e),
                                  ],
                                  [
                                    Color(0xffbb7e91),
                                    Color(0xff935264),
                                    Color(0xff68384c),
                                  ],
                                ])
                                  Padding(
                                    padding: const EdgeInsets.only(right: 4),
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        gradient: RadialGradient(
                                          center: const Alignment(-.48, -.55),
                                          radius: 1.25,
                                          colors: shades,
                                        ),
                                      ),
                                      child: const SizedBox.square(
                                        dimension: 25,
                                      ),
                                    ),
                                  ),
                                Container(
                                  width: 1,
                                  height: 38,
                                  margin: const EdgeInsets.only(
                                    left: 9,
                                    right: 13,
                                  ),
                                  color: AppColors.isDark
                                      ? Colors.white30
                                      : const Color(0xffcab6bd),
                                ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'My Makeup Bag',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 16,
                                          color: AppColors.isDark
                                              ? AppColors.textMain
                                              : const Color(0xff57243e),
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'Try your saved products',
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: AppColors.textMuted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(
                                  Icons.chevron_right,
                                  color: AppColors.isDark
                                      ? AppColors.textMain
                                      : const Color(0xff57243e),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: tiles.length,
                        padding: EdgeInsets.zero,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount:
                              MediaQuery.sizeOf(context).width /
                                      MediaQuery.textScalerOf(
                                        context,
                                      ).scale(1) >=
                                  350
                              ? 4
                              : 2,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                          mainAxisExtent:
                              96 +
                              (MediaQuery.textScalerOf(context).scale(1) - 1)
                                      .clamp(0.0, 3.0) *
                                  55,
                        ),
                        itemBuilder: (context, index) {
                          return _RiseIn(
                            delay: Duration(milliseconds: 40 * (index + 1)),
                            child: _ExploreTile(tile: tiles[index]),
                          );
                        },
                      ),
                    ),
                    _RiseIn(
                      delay: const Duration(milliseconds: 80),
                      child: _SectionTitle(
                        'Your looks',
                        trailing: Semantics(
                          button: true,
                          label: 'See all saved looks',
                          child: TextButton(
                            onPressed: () =>
                                _openAccount(context, const SavedLooksScreen()),
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.accentPink,
                              minimumSize: const Size(48, 48),
                            ),
                            child: const Text(
                              'See all',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                      ),
                    ),
                    _RiseIn(
                      delay: const Duration(milliseconds: 120),
                      child: _LooksStrip(
                        looks: _recentLooks(),
                        onTryOn: () => _openTryOn(context),
                        onOpen: () =>
                            _openAccount(context, const SavedLooksScreen()),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({
    required this.height,
    required this.greeting,
    required this.avatarUrl,
    required this.onProfile,
    required this.onTryOn,
    required this.onFindShade,
  });

  final double height;
  final String greeting;
  final String? avatarUrl;
  final VoidCallback onProfile;
  final VoidCallback onTryOn;
  final VoidCallback onFindShade;

  @override
  Widget build(BuildContext context) {
    final secondary = AppColors.accentPink;
    return Column(
      children: [
        ClipRRect(
          borderRadius: const BorderRadius.vertical(
            bottom: Radius.circular(28),
          ),
          child: SizedBox(
            height: height,
            width: double.infinity,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.asset(
                  'assets/images/hero_model.webp',
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                  errorBuilder: (_, _, _) =>
                      const ColoredBox(color: AppColors.primaryDark),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.34),
                        Colors.black.withValues(alpha: 0.0),
                        Colors.black.withValues(alpha: 0.0),
                        Colors.black.withValues(alpha: 0.62),
                      ],
                      stops: const [0.0, 0.28, 0.55, 1.0],
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    MediaQuery.paddingOf(context).top + 8,
                    16,
                    40,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Image.asset(
                                      'assets/images/oval_face_ivory.png',
                                      width: 23,
                                      height: 32,
                                    ),
                                    const SizedBox(width: 7),
                                    const Flexible(
                                      child: Text(
                                        'AR Makeup',
                                        style: TextStyle(
                                          fontFamily: 'serif',
                                          fontSize: 21,
                                          color: Color(0xfffff5e7),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  greeting,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Semantics(
                            button: true,
                            label: 'Profile',
                            child: Material(
                              color: const Color(0xffefd6dd),
                              shape: const CircleBorder(),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                customBorder: const CircleBorder(),
                                onTap: onProfile,
                                child: SizedBox(
                                  width: 48,
                                  height: 48,
                                  child: _AvatarFace(
                                    url: avatarUrl,
                                    greeting: greeting,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      const Text(
                        'Find your perfect look',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          height: 1.12,
                          letterSpacing: -0.4,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Try a look on camera, or match a foundation shade.',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Transform.translate(
          offset: const Offset(0, -28),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    button: true,
                    label: 'Open camera',
                    child: SizedBox(
                      height: 56,
                      child: ElevatedButton.icon(
                        onPressed: onTryOn,
                        icon: const Icon(Icons.photo_camera_outlined, size: 20),
                        label: const Text(
                          'Open camera',
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                          disabledForegroundColor: Colors.white,
                          elevation: 1,
                          shadowColor: Colors.black.withValues(alpha: 0.12),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Semantics(
                    button: true,
                    label: 'Find my shade',
                    child: SizedBox(
                      height: 56,
                      child: OutlinedButton.icon(
                        onPressed: onFindShade,
                        icon: Icon(
                          Icons.colorize_rounded,
                          size: 20,
                          color: secondary,
                        ),
                        label: Text(
                          'Find my shade',
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            height: 1.1,
                            color: secondary,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          backgroundColor: AppColors.surface,
                          foregroundColor: secondary,
                          side: BorderSide(color: secondary),
                          elevation: 1,
                          shadowColor: Colors.black.withValues(alpha: 0.08),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _AvatarFace extends StatelessWidget {
  const _AvatarFace({required this.url, required this.greeting});
  final String greeting;

  final String? url;

  @override
  Widget build(BuildContext context) {
    if (url == null || url!.isEmpty) {
      return Center(
        child: greeting.startsWith('Hi, ') && greeting.length > 4
            ? Text(
                greeting.substring(4).characters.first,
                style: const TextStyle(color: Color(0xff55253f), fontSize: 21),
              )
            : const Icon(Icons.person_outline, color: Color(0xff55253f)),
      );
    }
    final pixelWidth = (48 * MediaQuery.devicePixelRatioOf(context))
        .round()
        .clamp(48, 192);
    return CachedNetworkImage(
      imageUrl: upgradeImageUrl(url!),
      cacheManager: AppImageCache.manager,
      fit: BoxFit.cover,
      memCacheWidth: pixelWidth,
      fadeInDuration: Duration.zero,
      errorWidget: (_, _, _) =>
          const Icon(Icons.person_outline, color: Colors.white, size: 24),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, {this.trailing, this.accent = false});

  final bool accent;

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    AppColors.watch(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                color: accent ? AppColors.accentPink : AppColors.textMain,
                fontSize: 18,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _HomeTile {
  const _HomeTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

class _ExploreTile extends StatelessWidget {
  const _ExploreTile({required this.tile});

  final _HomeTile tile;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tile.label,
      child: Material(
        color: AppColors.surface,
        elevation: 0,
        shadowColor: const Color(0x14000000),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: tile.onTap,
          borderRadius: BorderRadius.circular(16),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: AppColors.isDark ? 0.28 : 0.05,
                  ),
                  blurRadius: 2,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      tile.icon,
                      color: AppColors.accentPink,
                      size: 20,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tile.label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    style: TextStyle(
                      color: AppColors.textMain,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      height: 1.15,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LooksStrip extends StatelessWidget {
  const _LooksStrip({
    required this.looks,
    required this.onTryOn,
    required this.onOpen,
  });

  final List<Map<String, dynamic>> looks;
  final VoidCallback onTryOn;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    if (looks.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: AppColors.isDark ? 0.28 : 0.05,
                ),
                blurRadius: 2,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Save your first look from try-on',
                  style: TextStyle(
                    color: AppColors.textMain,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: onTryOn,
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.accentPink,
                      minimumSize: const Size(48, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                    ),
                    child: const Text(
                      'Try on',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final cacheWidth = (132 * MediaQuery.devicePixelRatioOf(context))
        .round()
        .clamp(64, 480);

    return SizedBox(
      height: 188,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        itemCount: looks.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final look = looks[index];
          final name = (look['look_name'] as String?)?.trim();
          final label = (name == null || name.isEmpty) ? 'Saved look' : name;
          final rawUrl = look['preview_image_url'] as String?;
          final url = (rawUrl == null || rawUrl.trim().isEmpty)
              ? null
              : upgradeImageUrl(rawUrl);
          return Semantics(
            button: true,
            label: label,
            child: SizedBox(
              width: 132,
              child: Material(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onOpen,
                  child: Ink(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: url == null
                              ? ColoredBox(
                                  color: AppColors.primary.withValues(
                                    alpha: 0.1,
                                  ),
                                  child: Icon(
                                    Icons.photo_outlined,
                                    color: AppColors.accentPink,
                                  ),
                                )
                              : CachedNetworkImage(
                                  imageUrl: url,
                                  fit: BoxFit.cover,
                                  memCacheWidth: cacheWidth,
                                  fadeInDuration: Duration.zero,
                                  placeholder: (_, _) =>
                                      ColoredBox(color: AppColors.neutral200),
                                  errorWidget: (_, _, _) => ColoredBox(
                                    color: AppColors.primary.withValues(
                                      alpha: 0.1,
                                    ),
                                    child: Icon(
                                      Icons.photo_outlined,
                                      color: AppColors.accentPink,
                                    ),
                                  ),
                                ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                          child: Text(
                            label,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.textMain,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              height: 1.2,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _RiseIn extends StatefulWidget {
  const _RiseIn({required this.delay, required this.child});

  final Duration delay;
  final Widget child;

  @override
  State<_RiseIn> createState() => _RiseInState();
}

class _RiseInState extends State<_RiseIn> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  var _scheduled = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) return;
    if (_scheduled || _controller.isCompleted) return;
    _scheduled = true;
    final delay = widget.delay;
    Future<void>.delayed(delay, () {
      if (!mounted) return;
      if (MediaQuery.disableAnimationsOf(context)) return;
      _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = Curves.easeOut.transform(_controller.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 12),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}
