import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../config/app_config.dart';
import '../services/web_bridge.dart';
import '../utils/app_colors.dart';
import '../widgets/app_loader.dart';
import '../utils/image_url.dart';
import '../cache/looks_cache.dart';
import '../utils/app_image_cache.dart';
import 'package:cached_network_image/cached_network_image.dart';

// ── TAB ENUM ──────────────────────────────────────────────────────────────────

enum _LooksTab { all, favourites }

// ── SCREEN ────────────────────────────────────────────────────────────────────

class SavedLooksScreen extends StatefulWidget {
  const SavedLooksScreen({super.key});

  @override
  State<SavedLooksScreen> createState() => _SavedLooksScreenState();
}

class _SavedLooksScreenState extends State<SavedLooksScreen>
    with TickerProviderStateMixin {
  // ── Cache reference ────────────────────────────────────────────────────────
  final _cache = LooksCache.instance;

  // Local favourite set — kept in sync with cache
  final Set<String> _favouriteIds = {};

  _LooksTab _currentTab = _LooksTab.all;

  late final AnimationController _fadeCtrl;
  late final Animation<double> _fadeAnim;

  // Per-card heart bounce controllers keyed by lookId
  final Map<String, AnimationController> _heartControllers = {};

  // ── INIT ───────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();

    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
      value: 0.0, // Explicit start
    );
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);

    // Agar cache pehle se loaded hai toh animation skip karo — seedha 1.0 pe set karo
    if (_cache.isLoaded) {
      _fadeCtrl.value = 1.0;
    }

    for (final look in _cache.looks) {
      if (look['is_favourite'] == true) {
        _favouriteIds.add(look['id'] as String);
      }
    }

    _cache.addListener(_onCacheUpdate);
    _bootstrap();
  }

  @override
  void dispose() {
    _cache.removeListener(_onCacheUpdate);
    _fadeCtrl.dispose();
    for (final c in _heartControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ── CACHE LISTENER ─────────────────────────────────────────────────────────

  void _onCacheUpdate() {
    if (!mounted) return;
    // Re-sync favourite set with cache (handles external changes)
    for (final look in _cache.looks) {
      final id = look['id'] as String;
      if (look['is_favourite'] == true) {
        _favouriteIds.add(id);
      } else {
        _favouriteIds.remove(id);
      }
    }
    setState(() {});
  }

  // ── BOOTSTRAP ──────────────────────────────────────────────────────────────
  //
  // If cache is already loaded → show instantly + precache images.
  // If cache is loading → wait for it.
  // If cache is empty (first open after cold start) → fetch now.
  //
  Future<void> _bootstrap() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    if (_cache.isLoaded) {
      // Data already hai — seedha show karo. A stale copy refreshes behind it.
      if (mounted) {
        _favouriteIds.clear();
        for (final look in _cache.looks) {
          if (look['is_favourite'] == true) {
            _favouriteIds.add(look['id'] as String);
          }
        }
        setState(() {});
        // Agar controller already complete hai toh reset karke forward karo
        if (_fadeCtrl.isCompleted) {
          _fadeCtrl.value = 1.0; // Already visible raho
        } else {
          _fadeCtrl.forward();
        }
        _precacheImages();
      }
      _cache.prefetch(userId);
      return;
    }

    try {
      await _cache.prefetch(userId);
    } catch (_) {}

    if (mounted) {
      _favouriteIds.clear();
      for (final look in _cache.looks) {
        if (look['is_favourite'] == true) {
          _favouriteIds.add(look['id'] as String);
        }
      }
      setState(() {});
      _fadeCtrl.forward();
      _precacheImages();
    }
  }

  // ── PRECACHE IMAGES ────────────────────────────────────────────────────────
  //
  // Tells Flutter's image cache to download all thumbnails in the background.
  // When the list renders, images appear instantly from cache.
  //
  void _precacheImages() {
    for (final look in _cache.looks) {
      final url = look['preview_image_url'] as String?;
      if (url != null && url.isNotEmpty) {
        // CachedNetworkImage ka apna cache manager use karo
        CachedNetworkImageProvider(
          upgradeImageUrl(url),
          maxWidth: 400,
          cacheManager: AppImageCache.manager,
        ).resolve(const ImageConfiguration());
      }
    }
  }

  // ── REFRESH (pull-to-refresh) ──────────────────────────────────────────────

  Future<void> _refresh() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    _fadeCtrl.reset();
    await _cache.refresh(userId);
    _precacheImages();
    if (mounted) {
      _favouriteIds.clear();
      for (final look in _cache.looks) {
        if (look['is_favourite'] == true) {
          _favouriteIds.add(look['id'] as String);
        }
      }
      setState(() {});
      _fadeCtrl.forward();
    }
  }

  // ── HELPERS ────────────────────────────────────────────────────────────────

  String _formatDate(String isoString) {
    final date = DateTime.parse(isoString).toLocal();
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${date.day} ${months[date.month - 1]}, ${date.year}';
  }

  List<Map<String, dynamic>> get _visibleLooks {
    if (_currentTab == _LooksTab.favourites) {
      return _cache.looks
          .where((l) => _favouriteIds.contains(l['id'] as String))
          .toList();
    }
    return _cache.looks;
  }

  AnimationController _heartCtrl(String lookId) {
    return _heartControllers.putIfAbsent(
      lookId,
      () => AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 300),
        lowerBound: 0.85,
        upperBound: 1.0,
        value: 1.0,
      ),
    );
  }

  // ── TOGGLE FAVOURITE ───────────────────────────────────────────────────────

  Future<void> _toggleFavourite(String lookId) async {
    final wasLiked = _favouriteIds.contains(lookId);
    setState(() {
      if (wasLiked) {
        _favouriteIds.remove(lookId);
      } else {
        _favouriteIds.add(lookId);
      }
    });
    _cache.setFavourite(lookId, !wasLiked);

    // Bounce animation
    final ctrl = _heartCtrl(lookId);
    ctrl.reverse().then((_) => ctrl.forward());
    HapticFeedback.lightImpact();

    try {
      await Supabase.instance.client
          .from('saved_looks')
          .update({'is_favourite': !wasLiked})
          .eq('id', lookId);
    } catch (e) {
      // Revert optimistic update on failure
      if (mounted) {
        setState(() {
          if (wasLiked) {
            _favouriteIds.add(lookId);
          } else {
            _favouriteIds.remove(lookId);
          }
        });
        _cache.setFavourite(lookId, wasLiked);
      }
      debugPrint('❌ Toggle favourite failed: $e');
    }
  }

  // ── APPLY LOOK ─────────────────────────────────────────────────────────────

  Future<void> _applySavedLook(String lookId) async {
    showDialog(
      context: context,
      useRootNavigator: false,
      barrierDismissible: false,
      builder: (_) => Center(
        child: Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.border, width: 1),
          ),
          child: const Center(
            child: AppLoader(size: 32, strokeWidth: 2),
          ),
        ),
      ),
    );
    try {
      final items = await Supabase.instance.client
          .from('saved_look_items')
          .select()
          .eq('look_id', lookId);
      if (mounted) {
        final nav = Navigator.of(context);
        if (nav.canPop()) nav.pop(); // dismiss loader
        if (nav.canPop()) nav.pop(items); // return to TryOnScreen
      }
    } catch (e) {
      if (mounted) {
        final nav = Navigator.of(context);
        if (nav.canPop()) nav.pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to load look details.')),
        );
      }
    }
  }

  // ── DELETE LOOK ────────────────────────────────────────────────────────────

  Future<void> _deleteLook(String lookId) async {
    final confirm =
        await showDialog<bool>(
          context: context,
          barrierColor: Colors.black.withValues(alpha: 0.55),
          builder: (context) => Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(horizontal: 32),
            child: Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: AppColors.border, width: 1),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withValues(alpha: 0.10),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.delete_outline_rounded,
                      color: Colors.redAccent,
                      size: 26,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Delete Look?',
                    style: TextStyle(
                      color: AppColors.textMain,
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'This look will be permanently removed and cannot be recovered.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 13.5,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () => Navigator.pop(context, false),
                          child: Container(
                            height: 48,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: AppColors.border,
                                width: 1.2,
                              ),
                            ),
                            child: Center(
                              child: Text(
                                'Cancel',
                                style: TextStyle(
                                  color: AppColors.textMuted,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: GestureDetector(
                          onTap: () => Navigator.pop(context, true),
                          child: Container(
                            height: 48,
                            decoration: BoxDecoration(
                              color: Colors.redAccent,
                              borderRadius: BorderRadius.circular(14),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.redAccent.withValues(
                                    alpha: 0.30,
                                  ),
                                  blurRadius: 14,
                                  offset: const Offset(0, 5),
                                ),
                              ],
                            ),
                            child: const Center(
                              child: Text(
                                'Delete',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ) ??
        false;

    if (!confirm) return;

    // ── Optimistic remove from cache + UI ─────────────────────────────────
    _cache.remove(lookId);
    _favouriteIds.remove(lookId);
    _heartControllers[lookId]?.dispose();
    _heartControllers.remove(lookId);
    if (mounted) setState(() {});

    try {
      await Supabase.instance.client
          .from('saved_look_items')
          .delete()
          .eq('look_id', lookId);
      await Supabase.instance.client
          .from('saved_looks')
          .delete()
          .eq('id', lookId);
      if (mounted) _showInfoSnackBar('Look deleted.');
    } catch (e) {
      // Restore on failure — trigger a full refresh
      if (mounted) {
        await _refresh();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error deleting look: $e')));
      }
    }
  }

  // ── SHARE / OPEN ACTIONS ───────────────────────────────────────────────────

  Future<void> _shareImage(String imageUrl, String lookName) async {
    File? tempFile;
    try {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Preparing image…')));
      }
      final response = await http
          .get(Uri.parse(upgradeImageUrl(imageUrl)))
          .timeout(const Duration(seconds: 10));
      final dir = await getTemporaryDirectory();
      final safeName = lookName.replaceAll(RegExp(r'[^\w\-]'), '_');
      tempFile = File('${dir.path}/$safeName.jpg');
      await tempFile.writeAsBytes(response.bodyBytes);
      await Share.shareXFiles([
        XFile(tempFile.path),
      ], text: 'Check out my makeup look: $lookName!');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Failed to share image.')));
      }
    } finally {
      try {
        await tempFile?.delete();
      } catch (_) {}
    }
  }

  /// Opens the look on the website **in this user's own browser**, carrying
  /// their session so "Add all to cart" / checkout work without a second login.
  Future<void> _openInWeb(String lookId) async {
    await WebBridge.openAuthenticated(context, AppConfig.lookPath(lookId));
  }

  // The two links below are handed to other people, so they must stay
  // token-free — never build them from WebBridge.buildAuthenticatedUrl().

  Future<void> _copyLink(String lookId) async {
    await Clipboard.setData(
      ClipboardData(text: WebBridge.publicUrl(AppConfig.lookPath(lookId))),
    );
    if (mounted) _showInfoSnackBar('Link copied! 📋');
  }

  Future<void> _shareLink(String lookId, String lookName) async {
    final url = WebBridge.publicUrl(AppConfig.lookPath(lookId));
    await Share.share(
      'Check out my virtual makeup look "$lookName" here: $url',
    );
  }

  // ── SNACKBAR HELPER ────────────────────────────────────────────────────────

  void _showInfoSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor: AppColors.primary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ── BUILD ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    AppColors.watch(context);
    final topPad = MediaQuery.of(context).padding.top;
    final isLoading = !_cache.isLoaded;

    final signedOut = Supabase.instance.client.auth.currentUser == null;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          _buildHeader(topPad),
          Expanded(
            child: signedOut
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        'Sign in to see your saved looks.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 15,
                          height: 1.4,
                        ),
                      ),
                    ),
                  )
                : isLoading
                ? _buildSkeletonGrid() // shows skeleton instead of spinner
                : _cache.looks.isEmpty
                ? _buildEmptyState()
                : RefreshIndicator(
                    onRefresh: _refresh,
                    color: AppColors.primary,
                    backgroundColor: AppColors.surface,
                    displacement: 20,
                    child: FadeTransition(
                      opacity: _fadeAnim,
                      child: _visibleLooks.isEmpty
                          ? _buildEmptyFavourites()
                          : _buildGrid(),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  // ── HEADER ─────────────────────────────────────────────────────────────────

  Widget _buildHeader(double topPad) {
    final favCount = _cache.looks
        .where((l) => _favouriteIds.contains(l['id']))
        .length;
    return Container(
      padding: EdgeInsets.fromLTRB(20, topPad + 14, 20, 0),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border(bottom: BorderSide(color: AppColors.border, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.border, width: 1),
                  ),
                  child: Icon(
                    Icons.arrow_back_ios_new_rounded,
                    color: AppColors.textMain,
                    size: 15,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  'My Looks',
                  style: TextStyle(
                    color: AppColors.textMain,
                    fontWeight: FontWeight.w800,
                    fontSize: 22,
                    letterSpacing: -0.6,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 14),

          Row(
            children: [
              _buildTab(_LooksTab.all, 'All Looks', Icons.grid_view_rounded),
              const SizedBox(width: 8),
              _buildTab(
                _LooksTab.favourites,
                'Favourites',
                Icons.favorite_rounded,
                badge: favCount > 0 ? favCount : null,
              ),
            ],
          ),
          const SizedBox(height: 2),
        ],
      ),
    );
  }

  Widget _buildTab(_LooksTab tab, String label, IconData icon, {int? badge}) {
    final isSelected = _currentTab == tab;
    return GestureDetector(
      onTap: () => setState(() => _currentTab = tab),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(50),
          border: Border.all(
            color: isSelected ? AppColors.primary : AppColors.border,
            width: 1.2,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.28),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13,
              color: isSelected ? Colors.white : AppColors.textMuted,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : AppColors.textMuted,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                fontSize: 13,
              ),
            ),
            if (badge != null) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: isSelected
                      ? Colors.white.withValues(alpha: 0.25)
                      : AppColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '$badge',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: isSelected ? Colors.white : AppColors.primary,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── SKELETON GRID (shown while cache loads) ────────────────────────────────

  Widget _buildSkeletonGrid() {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
        childAspectRatio: 0.62,
      ),
      itemCount: 6, // show 6 skeleton cards
      itemBuilder: (_, __) => _SkeletonCard(),
    );
  }

  // ── GRID ───────────────────────────────────────────────────────────────────

  Widget _buildGrid() {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
        childAspectRatio: 0.62,
      ),
      itemCount: _visibleLooks.length,
      itemBuilder: (context, index) {
        final look = _visibleLooks[index];
        return _buildCard(
          lookId: look['id'] as String,
          lookName: look['look_name'] as String? ?? 'My Look',
          imageUrl: look['preview_image_url'] as String?,
          dateStr: look['created_at'] as String,
        );
      },
    );
  }

  // ── CARD ───────────────────────────────────────────────────────────────────

  Widget _buildCard({
    required String lookId,
    required String lookName,
    required String? imageUrl,
    required String dateStr,
  }) {
    final isFav = _favouriteIds.contains(lookId);
    final heartCtrl = _heartCtrl(lookId);

    return AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: isFav
                ? AppColors.primary.withValues(alpha: 0.35)
                : AppColors.border,
            width: isFav ? 1.5 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: isFav
                  ? AppColors.primary.withValues(alpha: 0.10)
                  : Colors.black.withValues(alpha: 0.05),
              blurRadius: isFav ? 20 : 10,
              spreadRadius: isFav ? 2 : 0,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Image area ───────────────────────────────────────────────
            Expanded(
              child: Stack(
                children: [
                  // Image
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: () => _openLookViewer(
                        lookId: lookId,
                        lookName: lookName,
                        imageUrl: imageUrl,
                        dateStr: dateStr,
                      ),
                      child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(22),
                      ),
                      child: imageUrl != null && imageUrl.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: upgradeImageUrl(imageUrl),
                              cacheManager: AppImageCache.manager,
                              memCacheWidth: 400,
                              fit: BoxFit.cover,
                              // Pehli baar load hone pr shimmer dikhao
                              placeholder: (context, url) => _buildShimmer(),
                              // Disk cache se aaye toh instant — koi shimmer nahi
                              fadeInDuration: Duration.zero,
                              fadeOutDuration: Duration.zero,
                              errorWidget: (context, url, error) =>
                                  _buildPlaceholder(),
                            )
                          : _buildPendingUploadPlaceholder(),
                      ),
                    ),
                  ),

                  // Bottom gradient scrim
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    height: 60,
                    child: ClipRRect(
                      borderRadius: BorderRadius.zero,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.45),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Favourite button
                  Positioned(
                    top: 10,
                    right: 10,
                    child: GestureDetector(
                      onTap: () => _toggleFavourite(lookId),
                      child: ScaleTransition(
                        scale: heartCtrl,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 220),
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: isFav
                                ? AppColors.primary
                                : Colors.black.withValues(alpha: 0.30),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isFav
                                  ? AppColors.primary
                                  : Colors.white.withValues(alpha: 0.20),
                              width: 1,
                            ),
                            boxShadow: isFav
                                ? [
                                    BoxShadow(
                                      color: AppColors.primary.withValues(
                                        alpha: 0.40,
                                      ),
                                      blurRadius: 10,
                                      offset: const Offset(0, 3),
                                    ),
                                  ]
                                : null,
                          ),
                          child: Center(
                            child: Icon(
                              isFav
                                  ? Icons.favorite_rounded
                                  : Icons.favorite_border_rounded,
                              color: Colors.white,
                              size: 16,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Date badge
                  Positioned(
                    bottom: 9,
                    left: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.38),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.12),
                          width: 0.8,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.calendar_today_rounded,
                            color: Colors.white.withValues(alpha: 0.80),
                            size: 9,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _formatDate(dateStr),
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.90),
                              fontSize: 9.5,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.1,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ── Info row ─────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 11),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (isFav)
                    Container(
                      width: 3,
                      height: 32,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          lookName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13.5,
                            color: AppColors.textMain,
                            letterSpacing: -0.2,
                          ),
                        ),
                        if (isFav) ...[
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Icon(
                                Icons.favorite_rounded,
                                color: AppColors.primary,
                                size: 9,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'Favourited',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),

                  // Menu
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: PopupMenuButton<int>(
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        Icons.more_vert_rounded,
                        color: AppColors.textMuted,
                        size: 18,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      color: AppColors.surface,
                      elevation: 6,
                      shadowColor: Colors.black.withValues(alpha: 0.12),
                      onSelected: (value) {
                        switch (value) {
                          case 6:
                            _applySavedLook(lookId);
                          case 0:
                            _toggleFavourite(lookId);
                          case 1:
                            if (imageUrl != null)
                              _shareImage(imageUrl, lookName);
                          case 2:
                            _openInWeb(lookId);
                          case 3:
                            _copyLink(lookId);
                          case 4:
                            _shareLink(lookId, lookName);
                          case 5:
                            _deleteLook(lookId);
                        }
                      },
                      itemBuilder: (context) => [
                        _menuItem(
                          6,
                          Icons.auto_fix_high_rounded,
                          'Apply in try-on',
                          true,
                          AppColors.textMain,
                        ),
                        _menuItem(
                          0,
                          isFav
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          isFav ? 'Remove Favourite' : 'Add to Favourites',
                          true,
                          isFav ? AppColors.primary : AppColors.textMain,
                        ),
                        const PopupMenuDivider(height: 1),
                        _menuItem(
                          1,
                          Icons.image_outlined,
                          'Share Image',
                          imageUrl != null,
                          AppColors.textMain,
                        ),
                        _menuItem(
                          2,
                          Icons.open_in_browser_rounded,
                          'Open in Web',
                          true,
                          AppColors.textMain,
                        ),
                        _menuItem(
                          3,
                          Icons.copy_rounded,
                          'Copy Link',
                          true,
                          AppColors.textMain,
                        ),
                        _menuItem(
                          4,
                          Icons.share_outlined,
                          'Share Link',
                          true,
                          AppColors.textMain,
                        ),
                        const PopupMenuDivider(height: 1),
                        _menuItem(
                          5,
                          Icons.delete_outline_rounded,
                          'Delete Look',
                          true,
                          Colors.redAccent,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
    );
  }

  void _openLookViewer({
    required String lookId,
    required String lookName,
    required String? imageUrl,
    required String dateStr,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (viewerContext) => _LookViewer(
          lookName: lookName,
          imageUrl: imageUrl,
          dateLabel: _formatDate(dateStr),
          onApply: () {
            Navigator.of(viewerContext).pop();
            _applySavedLook(lookId);
          },
        ),
      ),
    );
  }

  PopupMenuItem<int> _menuItem(
    int value,
    IconData icon,
    String label,
    bool enabled,
    Color color,
  ) {
    final effectiveColor = enabled
        ? color
        : AppColors.textMuted.withValues(alpha: 0.4);
    return PopupMenuItem<int>(
      value: value,
      enabled: enabled,
      height: 42,
      child: Row(
        children: [
          Icon(icon, color: effectiveColor, size: 18),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(
              color: effectiveColor,
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  // ── EMPTY STATES ───────────────────────────────────────────────────────────

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 92,
              height: 92,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.08),
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.18),
                  width: 1.5,
                ),
              ),
              child: Icon(
                Icons.face_retouching_natural_rounded,
                size: 40,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'No looks saved yet',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: AppColors.textMain,
                letterSpacing: -0.4,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Try on some makeup and save your favourite combinations here!',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14.5,
                color: AppColors.textMuted,
                height: 1.65,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyFavourites() {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: SizedBox(
        height: 400,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 92,
                  height: 92,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.08),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: AppColors.primary.withValues(alpha: 0.18),
                      width: 1.5,
                    ),
                  ),
                  child: Icon(
                    Icons.favorite_border_rounded,
                    size: 38,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'No favourites yet',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textMain,
                    letterSpacing: -0.4,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Tap the ♡ on any look to add it to your favourites.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14.5,
                    color: AppColors.textMuted,
                    height: 1.65,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: AppColors.primary.withValues(alpha: 0.06),
      child: Center(
        child: Icon(
          Icons.face_retouching_natural_rounded,
          color: AppColors.primary.withValues(alpha: 0.45),
          size: 36,
        ),
      ),
    );
  }

  // ── Shown when look was just saved and image upload is still in progress ───
  Widget _buildPendingUploadPlaceholder() {
    return Container(
      color: AppColors.primary.withValues(alpha: 0.06),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: AppLoader(
                size: 22,
                strokeWidth: 1.5,
                color: AppColors.primary.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Processing…',
              style: TextStyle(
                color: AppColors.primary.withValues(alpha: 0.6),
                fontSize: 10,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Proper shimmer animation shown while network image decodes
  Widget _buildShimmer() {
    return _ShimmerBox(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
    );
  }
}

// ── SKELETON CARD ─────────────────────────────────────────────────────────────

class _SkeletonCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.border, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(22),
              ),
              child: _ShimmerBox(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ShimmerBox(
                  width: 100,
                  height: 12,
                  borderRadius: BorderRadius.circular(6),
                ),
                const SizedBox(height: 6),
                _ShimmerBox(
                  width: 60,
                  height: 10,
                  borderRadius: BorderRadius.circular(5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── SHIMMER BOX ───────────────────────────────────────────────────────────────

class _ShimmerBox extends StatefulWidget {
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;

  const _ShimmerBox({this.width, this.height, this.borderRadius});

  @override
  State<_ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<_ShimmerBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) {
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            color: Color.lerp(
              AppColors.primary.withValues(alpha: 0.05),
              AppColors.primary.withValues(alpha: 0.13),
              _anim.value,
            ),
          ),
        );
      },
    );
  }
}

class _LookViewer extends StatelessWidget {
  const _LookViewer({
    required this.lookName,
    required this.imageUrl,
    required this.dateLabel,
    required this.onApply,
  });

  final String lookName;
  final String? imageUrl;
  final String dateLabel;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    AppColors.watch(context);
    final hasImage = imageUrl != null && imageUrl!.isNotEmpty;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded, color: Colors.white, size: 28),
              ),
            ),
            Expanded(
              child: hasImage
                  ? CachedNetworkImage(
                      imageUrl: upgradeImageUrl(imageUrl!),
                      cacheManager: AppImageCache.manager,
                      memCacheWidth: 1080,
                      fit: BoxFit.contain,
                      width: double.infinity,
                      placeholder: (_, _) => const Center(
                        child: AppLoader(size: 36, color: Colors.white),
                      ),
                      errorWidget: (_, _, _) => const Icon(
                        Icons.image_not_supported_outlined,
                        color: Colors.white54,
                        size: 48,
                      ),
                    )
                  : const Icon(
                      Icons.image_outlined,
                      color: Colors.white54,
                      size: 48,
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
              child: Column(
                children: [
                  Text(
                    lookName,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    dateLabel,
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: onApply,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: const Text(
                        'Apply in try-on',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
