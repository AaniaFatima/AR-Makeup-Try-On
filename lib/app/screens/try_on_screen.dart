import 'dart:math' as math;
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel, rootBundle, SystemUiOverlayStyle;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:deepar_flutter/deepar_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vector_math/vector_math_64.dart' as vector;
import '../utils/app_colors.dart';
import '../utils/face_guidance.dart';
import '../utils/color_utils.dart';
import '../utils/demo_looks.dart';
import '../utils/skin_color.dart';
import '../cache/looks_cache.dart';
import '../cache/shade_disk_cache.dart';
import '../config/app_config.dart';
import '../cache/pending_looks_queue.dart';
import '../services/beauty_profile_service.dart';
import '../services/foundation_match_service.dart';
import 'foundation_capture_screen.dart';
import 'foundation_match_screen.dart';
import 'saved_looks_screen.dart';
import 'auth_screen.dart';
import 'home_screen.dart';
import 'profile_screen.dart';
import '../cache/favourites_cache.dart';
import '../cache/makeup_bag_cache.dart';
import '../cache/products_cache.dart';
import '../services/web_bridge.dart';
import '../widgets/app_loader.dart';

// ── MODELS ───────────────────────────────────────────────────────────────────

class DbShade {
  final String productKey;
  final String shadeKey;
  final String shadeName;
  final String shadeHex;
  final int shadeOrder;

  DbShade({
    required this.productKey,
    required this.shadeKey,
    required this.shadeName,
    required this.shadeHex,
    required this.shadeOrder,
  });

  factory DbShade.fromMap(Map<String, dynamic> map) => DbShade(
    productKey: map['product_key']?.toString() ?? '',
    shadeKey: map['shade_key']?.toString() ?? '',
    shadeName: map['shade_name']?.toString() ?? '',
    shadeHex: map['shade_hex']?.toString() ?? '#000000',
    shadeOrder: (map['shade_order'] as num?)?.toInt() ?? 0,
  );

  Color get color {
    final cleaned = shadeHex.replaceAll('#', '').trim();
    return Color(int.parse('FF$cleaned', radix: 16));
  }
}

class DbLashConfig {
  final String productKey;
  final String baseMaskType;
  final String lashColor;
  final double opacity;
  final double scaleY;
  final double scaleX;

  DbLashConfig({
    required this.productKey,
    required this.baseMaskType,
    required this.lashColor,
    required this.opacity,
    required this.scaleY,
    required this.scaleX,
  });

  factory DbLashConfig.fromMap(Map<String, dynamic> map) => DbLashConfig(
    productKey: map['product_key']?.toString() ?? '',
    baseMaskType: map['base_mask_type']?.toString() ?? 'sexy',
    lashColor: map['lash_color']?.toString() ?? '#000000',
    opacity: (map['opacity'] as num?)?.toDouble() ?? 1.0,
    scaleY: (map['scale_y'] as num?)?.toDouble() ?? 1.0,
    scaleX: (map['scale_x'] as num?)?.toDouble() ?? 1.0,
  );

  Color get color {
    final cleaned = lashColor.replaceAll('#', '').trim();
    return Color(int.parse('FF$cleaned', radix: 16));
  }
}

// ── ENUMS ────────────────────────────────────────────────────────────────────

enum TryOnCategory {
  eyelashes,
  lipstick,
  lipGloss,
  foundation,
  blush,
  mascara,
  highlighter,
  eyeliner,
  eyeshadow,
}

// ── INTENSITY MAPPING ─────────────────────────────────────────────────────────
//
// UI shows 0–100 % to the user.
// _intensities stores 0.0–1.0 (the "user slider" value).
//
// _mapIntensityToBackend() maps the user's 0–1 value to the REAL
// backend alpha that makes each category look natural and realistic.
//
// Design constraints per category
// ────────────────────────────────
// Lipstick    : semi-matte; 100% alpha = plastic. Range 0.30 → 0.68
// Lip Gloss   : translucency IS the effect; high alpha kills shimmer. Range 0.38 → 0.60
// Foundation  : skin coverage, never opaque mask. Range 0.12 → 0.44
// Blush       : soft flush, easy to over-apply. Range 0.10 → 0.38  (+6% ceiling vs v1)
// Eyeshadow   : artistic; raised ceiling for dramatic looks. Range 0.15 → 0.82  (+7% ceiling vs v1)
// Eyeliner    : must be opaque even at low slider. Range 0.55 → 0.95
// Highlighter : subtle shimmer; ghost-white at high values. Range 0.10 → 0.44
// Lashes/Mascara: controlled via lash-config opacity × factor. Range 0.70 → 1.00
//
double _mapIntensityToBackend(TryOnCategory category, double userValue) {
  double lo, hi;
  switch (category) {
    case TryOnCategory.lipstick:
      lo = 0.30;
      hi = 0.68;
    case TryOnCategory.lipGloss:
      lo = 0.38;
      hi = 0.60;
    case TryOnCategory.foundation:
      lo = 0.12;
      hi = 0.44; // +0.02 → slightly more buildable coverage
    case TryOnCategory.blush:
      lo = 0.10;
      hi = 0.38; // was 0.08→0.32; raised ceiling so rosy flush reads clearly
    case TryOnCategory.eyeshadow:
      lo = 0.15;
      hi = 0.82; // was 0.15→0.75; raised for dramatic / smoky looks
    case TryOnCategory.eyeliner:
      lo = 0.55;
      hi = 0.95;
    case TryOnCategory.highlighter:
      lo = 0.10;
      hi = 0.44; // +0.02 → more visible glow at high slider
    case TryOnCategory.eyelashes:
    case TryOnCategory.mascara:
      lo = 0.70;
      hi = 1.00;
  }
  return lo + userValue * (hi - lo);
}

// ── SCREEN ───────────────────────────────────────────────────────────────────

class TryOnScreen extends StatefulWidget {
  const TryOnScreen({super.key, this.initialRequest});

  final Object? initialRequest;

  @override
  State<TryOnScreen> createState() => _TryOnScreenState();
}

class _TryOnScreenState extends State<TryOnScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  // ── DeepAR controller is created once and NEVER destroyed except in dispose().
  // Destroying on lifecycle-paused breaks navigation (Android treats route push
  // as a brief pause, which fires paused before the new surface is ready).
  late DeepArController _deepArController;
  Key _deepArKey = UniqueKey();

  bool _isInitialized = false;
  bool _initFailed = false;
  bool _cameraAccessOff = false;
  /// DeepAR face tracking. False until a face is reported, including an empty room.
  bool _faceVisible = false;

  /// Android count of `faceDetected` faces. Null until the first callback, and
  /// always null on iOS, where only [_faceVisible] is used.
  int? _trackedFaceCount;

  /// Debounced banner. The callbacks below only write the raw flags, then this.
  FaceGuidanceState _faceGuidance = const FaceGuidanceState();

  /// Wakes the grace / debounce when no further face callback arrives.
  Timer? _faceGuidanceTimer;
  bool _surfaceReady = false;
  // Guards against concurrent init calls (navigation races, resumed events)
  bool _initInProgress = false;

  // 🆕 FIX: Guards the WHOLE teardown → wait-for-surface → init cycle, not
  // just the initialize() call itself. This is the flag that actually stops
  // the double-teardown/double-init race that was crashing bgfx/GL on
  // resume-after-sign-in (SIGABRT in bgfx::gl::GlContext::resize).
  bool _reinitCycleActive = false;
  bool _cameraRebindInFlight = false;
  DateTime? _lastReinitAt;
  Timer? _initWatchdog;
  bool _shadeLoadSettled = false;
  String? _shadeLoadError;

  // 🆕 FIX v2 (real root cause): AuthScreen/ProfileScreen/SavedLooksScreen
  // are pushed onto THIS nested Navigator instead of the app's root
  // Navigator — see _pushOverlay() and the OVERLAY NAVIGATOR widget in
  // build() for the full explanation. _overlayActive just tracks whether
  // it currently has anything pushed, so we can toggle IgnorePointer /
  // forward the system back button to it.
  final GlobalKey<NavigatorState> _overlayNavKey = GlobalKey<NavigatorState>();
  bool _overlayActive = false;

  final String androidKey =
      "2952b3fa8af974da37a4802986a2b95c7383ea2f999dc94e83646b7ecab03d9c68e6232e888e8333";
  final String iosKey = "YAHAN_APNI_IOS_LICENSE_KEY_DALEIN";

  List<DbShade> _allDbShades = [];
  Map<String, DbLashConfig> _lashConfigs = {};
  /// False until the lash-config read finishes, including a timeout.
  bool _lashConfigsSettled = false;
  TryOnCategory _currentCategory = TryOnCategory.lipstick;
  bool _showOnlyMyBag = false;

  /// Skin tone measured by the foundation shade matcher, read from local storage
  /// on init. Kept separate from the Beauty Profile's own hex so the try-on sheet
  /// can sort by a real measurement offline, with no round trip.
  String? _measuredSkinHex;

  /// Saved recommendation from the last match that passed the quality gate.
  /// The closest badge uses these keys. A plain ΔE sort is only the fallback.
  String? _savedProductKey;
  String? _savedShadeKey;
  double? _savedDeltaE;

  /// ΔE2000 of the closest foundation shade, filled in by [_currentShades] while
  /// it sorts. Only used to label the first swatch.
  double? _closestFoundationDeltaE;

  final Map<TryOnCategory, DbShade?> _selectedShades = {
    for (var cat in TryOnCategory.values) cat: null,
  };

  // User-facing slider values: 0.0 → 1.0 (shown as 0–100 % in UI).
  // Defaults produce a realistic "first impression" look:
  //   lipstick   65 % → backend 0.509  (natural semi-matte)
  //   lip gloss  60 % → backend 0.492  (translucent gloss)
  //   foundation 40 % → backend 0.248  (light coverage)
  //   blush      52 % → backend 0.248  (natural flush, maps to new 0.10–0.38)
  //   eyeshadow  55 % → backend 0.467  (wearable, maps to new 0.15–0.82)
  //   eyeliner   80 % → backend 0.870  (crisp line)
  //   highlighter 45% → backend 0.247  (subtle glow)
  //   lashes/mas 85 % → backend 0.955  (full lash)
  final Map<TryOnCategory, double> _intensities = {
    TryOnCategory.eyelashes: 0.85,
    TryOnCategory.lipstick: 0.65,
    TryOnCategory.lipGloss: 0.60,
    TryOnCategory.foundation: 0.40,
    TryOnCategory.blush: 0.52,
    TryOnCategory.mascara: 0.85,
    TryOnCategory.highlighter: 0.45,
    TryOnCategory.eyeliner: 0.80,
    TryOnCategory.eyeshadow: 0.55,
  };

  // Cached temp-file paths for asset textures (avoids re-writing on every tap)
  final Map<String, String> _assetPathCache = {};

  bool _isSaveDialogOpen = false;
  Uint8List? _saveDialogFrameBytes;
  File? _saveDialogScreenshotFile;
  bool _isProcessingPendingSaves = false;

  /// Press-and-hold bare face. Live clear only; never switchEffect or dispose.
  bool _bareHoldActive = false;
  /// First-open coach: 0 Save, 1 Hold, 2 Compare. Null after it is dismissed.
  int? _coachStep;
  static const String _coachSeenKey = 'try_on_coach_seen_v1';
  int _bareToken = 0;
  bool _shadeCaptureBusy = false;

  /// Two-shade still compare. Files are deleted when the overlay closes.
  bool _comparePicking = false;
  TryOnCategory _comparePickCategory = TryOnCategory.lipstick;
  final List<DbShade> _comparePicks = [];
  bool _compareOpen = false;
  bool _compareChoosesShade = false;
  double _compareSplit = 0.5;
  Uint8List? _compareLeftBytes;
  Uint8List? _compareRightBytes;
  File? _compareLeftFile;
  File? _compareRightFile;
  String _compareLeftLabel = '';
  String _compareRightLabel = '';
  DbShade? _compareShadeA;
  DbShade? _compareShadeB;
  TryOnCategory? _compareShadeCategory;
  DbShade? _shadeBeforeCompare;
  String? _demoStatus;

  late AnimationController _panelController;
  late AnimationController _topBarController;
  late Animation<Offset> _panelSlide;
  late Animation<double> _panelFade;
  late Animation<Offset> _topBarSlide;
  late Animation<double> _topBarFade;

  // ── INIT ──────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _deepArController = DeepArController();
    _bindFaceVisibility(_deepArController);

    _panelController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _panelSlide = Tween<Offset>(begin: const Offset(0, 0.22), end: Offset.zero)
        .animate(
          CurvedAnimation(parent: _panelController, curve: Curves.easeOutCubic),
        );
    _panelFade = CurvedAnimation(
      parent: _panelController,
      curve: Curves.easeOut,
    );

    _topBarController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _topBarSlide = Tween<Offset>(begin: const Offset(0, -0.3), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _topBarController,
            curve: Curves.easeOutCubic,
          ),
        );
    _topBarFade = CurvedAnimation(
      parent: _topBarController,
      curve: Curves.easeOut,
    );

    _initialCatalog = _loadDataFromDb();
    _processPendingSavedLooks();
    _loadMeasuredSkinTone();
    _loadCoachMarks();

    // Claim the reinit cycle before the first frame. A `resumed` event often
    // arrives during startup; if it starts a second destroy/init while this
    // one is still waiting for the surface, DeepAR hangs and the spinner
    // never leaves.
    _reinitCycleActive = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Android SurfaceHolder.surfaceCreated() ko time do
      // 0.0.5 version mein koi callback nahi hai isliye
      // hum ek reliable multi-frame wait use karenge
      _waitForSurfaceThenInit();
    });
  }

  Future<void> _loadCoachMarks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted || prefs.getBool(_coachSeenKey) == true) return;
      setState(() => _coachStep = 0);
    } catch (e) {
      debugPrint('coach mark load failed: $e');
    }
  }

  Future<void> _advanceCoach() async {
    final step = _coachStep;
    if (step == null) return;
    if (step < 2) {
      setState(() => _coachStep = step + 1);
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_coachSeenKey, true);
    } catch (e) {
      debugPrint('coach mark save failed: $e');
    }
    if (mounted) setState(() => _coachStep = null);
  }

  late final Future<void> _initialCatalog;
  bool _initialRequestConsumed = false;

  Future<void> _applyInitialRequest() async {
    if (widget.initialRequest == null || _initialRequestConsumed) return;
    await _initialCatalog;
    if (!mounted || !_isInitialized || _initialRequestConsumed) return;
    _initialRequestConsumed = true;
    await _handleOverlayResult(widget.initialRequest);
  }

  Future<void> _openHome() async {
    final result = await _pushOverlay<Object>(const HomeScreen(overCamera: true));
    await _handleOverlayResult(result);
  }

  Future<void> _handleOverlayResult(Object? result) async {
    if (!mounted || result == null) return;
    if (result is List) {
      _loadAndApplySavedLook(result);
      return;
    }
    if (result == 'tryOnWithMyBag') {
      _enableBagFilter();
      return;
    }
    if (result is FoundationTryOnRequest) {
      await _loadMeasuredSkinTone();
      if (!mounted) return;
      await _applyShadeRequest('tryOn:${result.productKey}:${result.shadeKey}');
      return;
    }
    if (result is FoundationLookRequest) {
      await _loadMeasuredSkinTone();
      if (!mounted) return;
      await _applyHarmonyLook(result);
      return;
    }
    if (result is String && result.startsWith('tryOn:')) {
      await _applyShadeRequest(result);
    }
  }

  void _enableBagFilter() {
    final bagHasHighlighter = MakeupBagCache.instance.items.any((item) {
      final key = item['product_key']?.toString() ?? '';
      return key.startsWith('hgl_');
    });
    setState(() => _showOnlyMyBag = true);
    if (bagHasHighlighter) {
      _showSnack("Highlighter isn't in this effect.");
    }
  }

  /// Reads the last measured skin tone out of local storage.
  ///
  /// Fire-and-forget on purpose: nothing on the camera's critical path may wait
  /// for a disk read, and until it lands the foundation list simply shows in
  /// catalog order. Once it arrives the `setState` re-sorts the sheet.
  Future<void> _loadMeasuredSkinTone() async {
    final hex = await FoundationMatchService.cachedTryOnHex();
    final saved = await FoundationMatchService.cachedSummary();
    if (!mounted) return;
    setState(() {
      if (hex != null && hex.isNotEmpty) _measuredSkinHex = hex;
      _savedProductKey = saved?.productKey;
      _savedShadeKey = saved?.shadeKey;
      _savedDeltaE = saved?.deltaE;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final left = _compareLeftFile;
    final right = _compareRightFile;
    _compareLeftFile = null;
    _compareRightFile = null;
    _compareLeftBytes = null;
    _compareRightBytes = null;
    _deleteShot(left);
    _deleteShot(right);
    // Always destroy — this is the only place we tear down the controller.
    try {
      _deepArController.destroy();
    } catch (_) {}
    _initWatchdog?.cancel();
    _faceGuidanceTimer?.cancel();
    _panelController.dispose();
    _topBarController.dispose();
    super.dispose();
  }

  // ── LIFECYCLE ─────────────────────────────────────────────────────────────
  //
  // KEY RULE: When app is paused (navigation away), the Android SurfaceView's
  // native surface becomes invalid. On resume, we destroy the old controller
  // and create a fresh one. We keep the same widget key to avoid rebuilding
  // the SurfaceView widget (which can cause race conditions). The same
  // SurfaceView will reattach its surface.
  //
  // 🆕 FIX: Both this handler AND the explicit post-navigation calls
  // (_showLoginPrompt, Saved/Profile navigation) used to be able to fire
  // _waitForSurfaceThenInit()/_destroyAndResetController() independently and
  // almost simultaneously (e.g. when returning from AuthScreen, Android can
  // deliver a slightly-delayed `resumed` event on top of the explicit
  // post-Navigator.push() call). That produced TWO overlapping
  // destroy()/initialize() cycles on the same native GL/bgfx context, which
  // is what caused the SIGABRT crash. _reinitCycleActive + a short debounce
  // now make sure only ONE reinit cycle can run at a time, from whichever
  // path triggers it first.
  //
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _teardownDeepAR();
    } else if (state == AppLifecycleState.paused) {
      // Mark surface as invalid — it will be detached during Android pause
      if (mounted) {
        debugPrint('App paused — marking surface as invalid');
        setState(() => _surfaceReady = false);
      }
    } else if (state == AppLifecycleState.resumed) {
      if (mounted) {
        _processPendingSavedLooks();
      }

      // 🔧 FIX: Only reinitialize if TryOnScreen is actually current (visible)
      // If another screen (AuthScreen) is on top, don't try to initialize
      // as the SurfaceView won't be visible and will cause EGL_BAD_NATIVE_WINDOW
      //
      // 🆕 FIX: Also skip if a reinit cycle is already in flight (started by
      // this handler or by an explicit post-navigation call) and skip if we
      // just did a reinit a moment ago (debounce), since Android can fire
      // `resumed` more than once in quick succession around navigation.
      // The match flow sits on the nested overlay, so this route stays
      // "current" while the camera plugin owns the device. A resume reinit
      // here would start a second DeepAR session on top of that.
      if (mounted && !_initInProgress && !_reinitCycleActive && !_overlayActive) {
        final isCurrent = ModalRoute.of(context)?.isCurrent ?? false;

        final now = DateTime.now();
        final tooSoon = _lastReinitAt != null &&
            now.difference(_lastReinitAt!) < const Duration(milliseconds: 1500);

        if (isCurrent && !tooSoon) {
          debugPrint('App resumed — TryOnScreen is current, reinitializing AR');
          _lastReinitAt = now;
          _reinitCycleActive = true;

          _destroyAndResetController().then((_) {
            if (!mounted) {
              _reinitCycleActive = false;
              return;
            }
            setState(() => _surfaceReady = false);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                _waitForSurfaceThenInit();
              } else {
                _reinitCycleActive = false;
              }
            });
          });
        } else {
          debugPrint(
            'App resumed — skipping AR reinit (not current, or too soon after last reinit)',
          );
        }
      }
    }
  }

  // 🔧 NEW: Destroy old controller and reset state for fresh surface attachment
  //
  // 🆕 FIX: Now async and properly AWAITS the native destroy() call, plus a
  // short buffer delay before creating the replacement controller. Previously
  // destroy() was fired without awaiting its completion, so a brand-new
  // initialize() could start on the native side before the old GL/bgfx
  // context had actually finished tearing down — a second source of the
  // same race that caused the crash.
  Future<void> _destroyAndResetController() async {
    try {
      await _deepArController.destroy();
    } catch (e) {
      debugPrint('Controller destroy on resume failed: $e');
    }

    // Give the native render thread a moment to fully finish cleanup
    // before a new controller starts talking to the same SurfaceView.
    await Future.delayed(const Duration(milliseconds: 150));

    _deepArController = DeepArController();
    _bindFaceVisibility(_deepArController);
    // 🔧 IMPORTANT: Do NOT change _deepArKey!
    // Changing the key forces SurfaceView widget to rebuild, which can cause
    // the old surface to linger while new one is being created, causing
    // EGL_BAD_NATIVE_WINDOW errors. Instead, keep the same widget and just
    // swap the controller. The same SurfaceView will reattach its surface.
    _faceGuidanceTimer?.cancel();
    _faceGuidanceTimer = null;
    if (mounted) {
      setState(() {
        _isInitialized = false;
        _initFailed = false;
        _faceVisible = false;
        _trackedFaceCount = null;
        _faceGuidance = const FaceGuidanceState();
        _cameraAccessOff = false;
      });
    }
  }

  Future<ShadeDiskSnapshot> _loadShadesFromCache() async {
    try {
      final disk = await ShadeDiskCache.read();
      if (disk.shades.isNotEmpty && mounted) {
        setState(() {
          _allDbShades = disk.shades
              .map((item) => DbShade.fromMap(item))
              .toList();
          _shadeLoadSettled = true;
          _shadeLoadError = null;
        });
      }
      return disk;
    } catch (e) {
      debugPrint('❌ Shade cache load failed: $e');
      return const ShadeDiskSnapshot(cachedAt: null, shades: []);
    }
  }

  Future<void> _saveShadesToCache(List<Map<String, dynamic>> shades) async {
    try {
      await ShadeDiskCache.write(shades, DateTime.now());
    } catch (e) {
      debugPrint('❌ Shade cache write failed: $e');
    }
  }

  Future<void> _clearSaveDialogFreeze() async {
    if (!mounted) return;
    setState(() {
      _isSaveDialogOpen = false;
      _saveDialogFrameBytes = null;
      _saveDialogScreenshotFile = null;
    });
  }

  Future<File?> _captureFreezeFrame() async {
    if (!_isInitialized) return null;
    try {
      final screenshot = await _deepArController.takeScreenshot();
      final bytes = await screenshot.readAsBytes();
      if (!mounted) return null;
      setState(() {
        _saveDialogFrameBytes = bytes;
        _saveDialogScreenshotFile = screenshot;
      });
      return screenshot;
    } catch (e) {
      debugPrint('❌ Save-dialog freeze capture failed: $e');
      return null;
    }
  }

  Future<void> _processPendingSavedLooks() async {
    if (_isProcessingPendingSaves) return;
    _isProcessingPendingSaves = true;
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) return;

      await PendingLooksQueue.instance.load();
      final pending = PendingLooksQueue.instance.pending;
      if (pending.isEmpty) return;

      for (final pendingLook in List<Map<String, dynamic>>.from(pending)) {
        try {
          await _syncPendingLook(pendingLook);
        } catch (e) {
          debugPrint('❌ Pending look sync failed: $e');
        }
      }
    } finally {
      _isProcessingPendingSaves = false;
    }
  }

  Future<void> _syncPendingLook(Map<String, dynamic> pendingLook) async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    final previewPath = pendingLook['preview_image_path'] as String?;
    if (previewPath == null) {
      throw ('Missing pending preview path');
    }

    final previewFile = File(previewPath);
    if (!await previewFile.exists()) {
      throw ('Pending preview file missing');
    }

    String? previewUrl;
    try {
      final fileName = '${userId}_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final bytes = await previewFile.readAsBytes();
      await Supabase.instance.client.storage
          .from('looks')
          .uploadBinary(fileName, bytes);
      previewUrl = Supabase.instance.client.storage
          .from('looks')
          .getPublicUrl(fileName);
    } catch (e) {
      throw ('Pending image upload failed: $e');
    }

    final lookRes = await Supabase.instance.client
        .from('saved_looks')
        .insert({
          'user_id': userId,
          'look_name': pendingLook['look_name'],
          'preview_image_url': previewUrl,
        })
        .select('id')
        .single();
    final lookId = lookRes['id'].toString();

    final items = (pendingLook['items'] as List<dynamic>)
        .map((item) => Map<String, dynamic>.from(item as Map<String, dynamic>))
        .toList();
    final itemsToInsert = items
        .map((entry) => {...entry, 'look_id': lookId})
        .toList();

    if (itemsToInsert.isNotEmpty) {
      await Supabase.instance.client
          .from('saved_look_items')
          .insert(itemsToInsert);
    }

    await PendingLooksQueue.instance.remove(pendingLook['id'] as String);
    await LooksCache.instance.refresh(userId);
  }

  Future<void> _queueLookForLater(
    String userId,
    String lookName,
    File previewFile,
    List<Map<String, dynamic>> items,
  ) async {
    final pendingId = 'pending_${DateTime.now().millisecondsSinceEpoch}';
    final pendingLook = {
      'id': pendingId,
      'user_id': userId,
      'look_name': lookName,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'is_favourite': false,
      'items': items,
    };

    await PendingLooksQueue.instance.add(pendingLook, previewFile);
    final pendingCacheLook = {
      'id': pendingId,
      'user_id': userId,
      'look_name': lookName,
      'preview_image_url': '',
      'created_at': pendingLook['created_at'],
      'is_favourite': false,
      'is_pending': true,
    };
    LooksCache.instance.optimisticAdd(pendingCacheLook);
  }

  // ── DB LOAD ───────────────────────────────────────────────────────────────
  // This method waits for the Android SurfaceView's surface to be fully ready
  // before initializing DeepAR. This is critical after navigation when the
  // surface has been reattached to a new SurfaceView instance.
  //
  // 🆕 FIX: This is now the single owner of `_reinitCycleActive` for the
  // "wait then init" half of the cycle. It sets the flag on entry (in case it
  // was called directly, e.g. from _showLoginPrompt, rather than via
  // didChangeAppLifecycleState) and always clears it on every exit path so a
  // future resume/navigation can trigger a fresh cycle.
  //
  void _giveUpOnCamera(String reason) {
    debugPrint('DeepAR: $reason');
    _initWatchdog?.cancel();
    _initInProgress = false;
    _reinitCycleActive = false;
    if (!mounted) return;
    setState(() {
      _isInitialized = false;
      _initFailed = true;
    });
  }

  void _armInitWatchdog() {
    _initWatchdog?.cancel();
    _initWatchdog = Timer(const Duration(seconds: 16), () {
      if (!mounted || _isInitialized) return;
      _giveUpOnCamera('camera did not start');
    });
  }

  Future<void> _waitForSurfaceThenInit() async {
    if (!mounted) {
      _reinitCycleActive = false;
      return;
    }

    _reinitCycleActive = true;
    _armInitWatchdog();

    // 🔧 Surface reattachment wait
    // Since we're NOT changing widget key, same SurfaceView reattaches surface
    debugPrint('Waiting for surface to be ready...');

    try {
      // Wait 8 frames for layout
      for (int i = 0; i < 8; i++) {
        await Future.delayed(const Duration(milliseconds: 16));
        if (!mounted) {
          _reinitCycleActive = false;
          _initWatchdog?.cancel();
          return;
        }
      }

      // 🔧 Reduced from 1200ms to 600ms
      // Same SurfaceView reattaches surface faster than creating new one
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) {
        _reinitCycleActive = false;
        _initWatchdog?.cancel();
        return;
      }

      debugPrint('Surface ready — proceeding with DeepAR initialization');
      if (mounted) setState(() => _surfaceReady = true);
      await _initializeDeepAR();
    } catch (e, st) {
      debugPrint('DeepAR startup failed: $e\n$st');
      _giveUpOnCamera('startup failed');
    } finally {
      _reinitCycleActive = false;
      if (_isInitialized || _initFailed) _initWatchdog?.cancel();
    }

    // Capture can finish while this cycle still owns the reinit flag.
    // Resume only after the flag is clear, so it is not dropped.
    if (mounted) await _resumeDeepArAfterPluginCamera();
  }

  // ── CATEGORY HELPERS ──────────────────────────────────────────────────────
  Future<void> _teardownDeepAR() async {
    if (!_isInitialized && !_initInProgress) return;

    _initInProgress = false;

    // 🆕 Surface flag bhi reset karo
    _faceGuidanceTimer?.cancel();
    _faceGuidanceTimer = null;
    if (mounted)
      setState(() {
        _isInitialized = false;
        _surfaceReady = false; // 🆕
        _faceVisible = false;
        _trackedFaceCount = null;
        _faceGuidance = const FaceGuidanceState();
      });

    try {
      await _deepArController.destroy();
    } catch (_) {}

    _deepArController = DeepArController();
    _bindFaceVisibility(_deepArController);
    _deepArKey = UniqueKey();
  }

  void _bindFaceVisibility(DeepArController controller) {
    controller.onFaceVisibilityChanged = (visible) {
      if (!mounted || _faceVisible == visible) return;
      final now = DateTime.now();
      setState(() {
        _faceVisible = visible;
        _faceGuidance = reduceFaceGuidance(
          _faceGuidance,
          faceVisible: visible,
          now: now,
        );
      });
      _armFaceGuidanceTimer();
    };
    controller.onFaceCountChanged = (count) {
      if (!mounted || _trackedFaceCount == count) return;
      final now = DateTime.now();
      setState(() {
        _trackedFaceCount = count;
        _faceGuidance = reduceFaceGuidance(
          _faceGuidance,
          faceCount: count,
          countEvent: true,
          now: now,
        );
      });
      _armFaceGuidanceTimer();
    };
  }

  /// Lets grace and the several-faces debounce finish with no new callback.
  /// Does not start, stop, or rebind DeepAR.
  void _armFaceGuidanceTimer() {
    _faceGuidanceTimer?.cancel();
    final wake = _faceGuidance.wakeAt;
    if (wake == null) {
      _faceGuidanceTimer = null;
      return;
    }
    var delay = wake.difference(DateTime.now());
    if (delay < Duration.zero) delay = Duration.zero;
    _faceGuidanceTimer = Timer(delay, () {
      if (!mounted) return;
      setState(() {
        _faceGuidance = reduceFaceGuidance(_faceGuidance, now: DateTime.now());
      });
      _armFaceGuidanceTimer();
    });
  }

  /// Why Save, Hold, and Compare capture are blocked, or null when exactly
  /// one face is accepted.
  ///
  /// A missing count (no callback yet, or iOS) keeps the visibility check only.
  /// A count from before the face left is not treated as several faces.
  /// Try-on has no Share control; this is the gate for Save look.
  String? _faceBlockReason() => _faceGuidance.blockReason;

  /// Shows the existing no-face or several-faces line and reports that the
  /// frame must not be taken. Category chips do not call this.
  bool _rejectFrameCapture({required bool allowed}) {
    if (allowed) return false;
    final message = _faceBlockReason();
    if (message != null) _showSnack(message);
    return true;
  }

  bool _isHighlighter({TryOnCategory? category, String? productKey}) {
    if (category == TryOnCategory.highlighter) return true;
    return productKey != null && productKey.startsWith('hgl_');
  }

  String _getGameObject(TryOnCategory category) {
    switch (category) {
      case TryOnCategory.lipstick:
      case TryOnCategory.lipGloss:
        return 'lips';
      case TryOnCategory.blush:
        return 'Blush';
      case TryOnCategory.eyeshadow:
        return 'EyeShadow';
      case TryOnCategory.eyeliner:
        return 'Eyeliner';
      case TryOnCategory.eyelashes:
      case TryOnCategory.mascara:
        return 'EyeLashes';
      case TryOnCategory.foundation:
        return 'face_makeup';
      case TryOnCategory.highlighter:
        return 'Highlighter';
    }
  }

  String get _currentPrefix => _prefixFor(_currentCategory);

  /// The `product_key` prefix that identifies [category] in the database.
  ///
  /// Split out of [_currentPrefix] so the same table can be walked in reverse by
  /// [_categoryForPrefix]. One mapping, not two that can silently drift apart.
  static String _prefixFor(TryOnCategory category) {
    switch (category) {
      case TryOnCategory.eyelashes:
        return 'lsh_';
      case TryOnCategory.lipstick:
        return 'lip_';
      case TryOnCategory.lipGloss:
        return 'gloss_';
      case TryOnCategory.foundation:
        return 'fnd_';
      case TryOnCategory.blush:
        return 'blu_';
      case TryOnCategory.mascara:
        return 'mas_';
      case TryOnCategory.highlighter:
        return 'hgl_';
      case TryOnCategory.eyeliner:
        return 'eln_';
      case TryOnCategory.eyeshadow:
        return 'esh_';
    }
  }

  String _prefixForKey(String productKey) {
    if (productKey.startsWith('lsh_')) return 'lsh_';
    if (productKey.startsWith('lip_')) return 'lip_';
    if (productKey.startsWith('gloss_')) return 'gloss_';
    if (productKey.startsWith('fnd_')) return 'fnd_';
    if (productKey.startsWith('blu_')) return 'blu_';
    if (productKey.startsWith('mas_')) return 'mas_';
    if (productKey.startsWith('hgl_')) return 'hgl_';
    if (productKey.startsWith('eln_')) return 'eln_';
    if (productKey.startsWith('esh_')) return 'esh_';
    return '';
  }

  TryOnCategory? _categoryForPrefix(String prefix) {
    switch (prefix) {
      case 'lsh_':
        return TryOnCategory.eyelashes;
      case 'lip_':
        return TryOnCategory.lipstick;
      case 'gloss_':
        return TryOnCategory.lipGloss;
      case 'fnd_':
        return TryOnCategory.foundation;
      case 'blu_':
        return TryOnCategory.blush;
      case 'mas_':
        return TryOnCategory.mascara;
      case 'hgl_':
        return TryOnCategory.highlighter;
      case 'eln_':
        return TryOnCategory.eyeliner;
      case 'esh_':
        return TryOnCategory.eyeshadow;
      default:
        return null;
    }
  }

  /// Mascara shares the lash mesh and draws nothing without a config row.
  /// Stay hidden until that row is known to exist.
  bool get _showMascaraChip =>
      _lashConfigsSettled &&
      _lashConfigs.keys.any((key) => key.startsWith('mas_'));

  String _getCategoryName(TryOnCategory cat) {
    switch (cat) {
      case TryOnCategory.eyelashes:
        return 'Lashes';
      case TryOnCategory.lipstick:
        return 'Lipstick';
      case TryOnCategory.lipGloss:
        return 'Lip Gloss';
      case TryOnCategory.foundation:
        return 'Foundation';
      case TryOnCategory.blush:
        return 'Blush';
      case TryOnCategory.mascara:
        return 'Mascara';
      case TryOnCategory.highlighter:
        return 'Highlighter';
      case TryOnCategory.eyeliner:
        return 'Eyeliner';
      case TryOnCategory.eyeshadow:
        return 'Eyeshadow';
    }
  }

  IconData _getCategoryIcon(TryOnCategory cat) {
    switch (cat) {
      case TryOnCategory.eyelashes:
        return Icons.remove;
      case TryOnCategory.lipstick:
        return Icons.water_drop_outlined;
      case TryOnCategory.lipGloss:
        return Icons.auto_awesome_outlined;
      case TryOnCategory.foundation:
        return Icons.circle_outlined;
      case TryOnCategory.blush:
        return Icons.blur_circular_outlined;
      case TryOnCategory.mascara:
        return Icons.minimize_rounded;
      case TryOnCategory.highlighter:
        return Icons.flare_outlined;
      case TryOnCategory.eyeliner:
        return Icons.edit_outlined;
      case TryOnCategory.eyeshadow:
        return Icons.palette_outlined;
    }
  }

  List<DbShade> get _currentShades {
    var filtered = _allDbShades
        .where((s) => s.productKey.startsWith(_currentPrefix))
        .toList();
    
    if (_showOnlyMyBag) {
      filtered = filtered
          .where((s) => MakeupBagCache.instance.isInBag(s.productKey, s.shadeKey))
          .toList();
    }

    // 💚 Foundation is the one category where shade order is not arbitrary: the
    // shade closest to the user's own skin belongs first.
    //
    // NOTE: this compares against `'fnd_'`, which is what `_currentPrefix`
    // actually returns for foundation (see line ~687). It read `'foundation'`
    // until now, so this block and the badge below had never once run.
    if (_currentPrefix == 'fnd_' && filtered.isNotEmpty) {
      final skinHex = _foundationSkinHex;
      final savedProduct = _savedProductKey;
      final savedShade = _savedShadeKey;
      final savedIndex = (savedProduct != null &&
              savedProduct.isNotEmpty &&
              savedShade != null &&
              savedShade.isNotEmpty)
          ? filtered.indexWhere(
              (s) => s.productKey == savedProduct && s.shadeKey == savedShade,
            )
          : -1;
      if (savedIndex >= 0) {
        if (savedIndex > 0) {
          final pinned = filtered.removeAt(savedIndex);
          filtered.insert(0, pinned);
        }
        _closestFoundationDeltaE = _savedDeltaE;
      } else if (skinHex != null) {
        // ΔE2000, not RGB distance. Two shades an equal number of RGB steps from
        // your skin are not equally wrong on your face — that is the whole reason
        // the CIE published a perceptual metric. `skin_color.dart` implements it.
        final scored = scoreShadesBySkinTone(
          filtered
              .map((s) => <String, dynamic>{
                    '_id': '${s.productKey}__${s.shadeKey}',
                    'hex': s.shadeHex,
                  })
              .toList(),
          skinHex,
        );

        final rank = <String, int>{};
        for (var i = 0; i < scored.length; i++) {
          rank[scored[i].shade['_id'] as String] = i;
        }
        // Anything missing from `rank` sorts last rather than throwing.
        const unranked = 1 << 20;
        filtered.sort((a, b) => (rank['${a.productKey}__${a.shadeKey}'] ?? unranked)
            .compareTo(rank['${b.productKey}__${b.shadeKey}'] ?? unranked));

        // Stashed for the badge on the first swatch. A plain field, not setState:
        // this runs inside build and must not schedule another one.
        final closest = scored.isNotEmpty ? scored.first.deltaE : double.infinity;
        _closestFoundationDeltaE = closest.isFinite ? closest : null;
      } else {
        _closestFoundationDeltaE = null;
      }
    }

    return filtered;
  }

  /// The colour the foundation list is sorted against, or null if unknown.
  ///
  /// Prefer the mapped catalog colour from the last match (`referenceHex`).
  /// An older server that did not send one falls back to the measured skin hex,
  /// then to the questionnaire.
  String? get _foundationSkinHex {
    if (_measuredSkinHex != null && _measuredSkinHex!.isNotEmpty) {
      return _measuredSkinHex;
    }
    final profile = BeautyProfileService.getCachedProfile();
    if (profile == null) return null;
    final hex = profile.skinToneHex;
    if (hex != null && hex.isNotEmpty) return hex;
    final fallback = depthLevelToHex(profile.depthLevel);
    return (fallback != null && fallback.isNotEmpty) ? fallback : null;
  }

  /// Badge colour for a ΔE2000 value, using the same bands as [describeDeltaE]
  /// so the colour and the words can never contradict each other.
  Color _deltaEBadgeColour(double? deltaE) {
    if (deltaE == null) return const Color(0xFF2E9E5B);
    if (deltaE < 3) return const Color(0xFF2E9E5B); // very close
    if (deltaE < 5) return const Color(0xFF7FA82E); // close
    if (deltaE < 8) return const Color(0xFFD98324); // noticeably different
    return AppColors.error; // clearly different
  }

  /// Applies a `tryOn:<productKey>:<shadeKey>` request popped by another screen.
  ///
  /// Uses `split` with a limit of three rather than a plain split, because a shade
  /// key is free text from the database and could legitimately contain a colon.
  Future<void> _applyShadeRequest(String request) async {
    final rest = request.substring('tryOn:'.length);
    final sep = rest.indexOf(':');
    if (sep < 0) return;
    final productKey = rest.substring(0, sep);
    final shadeKey = rest.substring(sep + 1);
    if (productKey.isEmpty) return;

    // The shade list may not have loaded yet on a cold start.
    if (_allDbShades.isEmpty) {
      await _loadDataFromDb();
      if (!mounted) return;
    }

    DbShade? target;
    for (final s in _allDbShades) {
      if (s.productKey == productKey && s.shadeKey == shadeKey) {
        target = s;
        break;
      }
    }
    // Fall back to any shade of the same product: the matcher recommended a
    // colour that exists in the catalog, so a missing shade row means the two
    // sources are out of sync, and showing the product is better than nothing.
    if (target == null) {
      for (final s in _allDbShades) {
        if (s.productKey == productKey) {
          target = s;
          break;
        }
      }
    }
    if (target == null) {
      _showSnack("That shade isn't in the try-on catalog yet.");
      return;
    }

    final category = _categoryForProductKey(target.productKey);
    if (category == null) {
      _showSnack("That product can't be tried on in AR yet.");
      return;
    }
    if (_isHighlighter(category: category, productKey: target.productKey)) {
      _showSnack("Highlighter isn't in this effect.");
      return;
    }

    final shade = target; // promoted, so the closure below needs no null checks
    setState(() {
      _currentCategory = category;
      _selectedShades[category] = shade;
      // A shade the user explicitly asked to try must be visible even when the
      // sheet is filtered to their bag and this shade is not in it.
      if (_showOnlyMyBag &&
          !MakeupBagCache.instance.isInBag(shade.productKey, shade.shadeKey)) {
        _showOnlyMyBag = false;
      }
    });

    _applyColorToDeepAR(shade, category);
    _showSnack('✨ Trying ${shade.shadeName}');
  }

  /// One-line status message. Clears any previous snack first so a burst of
  /// actions does not queue five toasts the user has to sit through.
  void _showSnack(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
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

  /// Reverse of [_currentPrefix]: which category owns a given `product_key`.
  TryOnCategory? _categoryForProductKey(String productKey) {
    for (final category in TryOnCategory.values) {
      if (productKey.startsWith(_prefixFor(category))) return category;
    }
    return null;
  }

  /// Opens the shade matcher over the camera.
  ///
  /// Uses [_pushOverlay] rather than the root Navigator — see the long note there.
  /// Pushing this on the root Navigator would tear down DeepAR's SurfaceView and
  /// the user would come back to a black screen.
  Future<void> _openFoundationMatcher() async {
    final request = await _pushOverlay<Object>(const FoundationMatchScreen());

    if (!mounted) return;

    // Re-read the measurement whether or not a shade was picked: the run may have
    // produced a new tone, which changes the order of this very list.
    await _loadMeasuredSkinTone();
    if (!mounted) return;

    if (request is FoundationTryOnRequest) {
      await _applyShadeRequest(
        'tryOn:${request.productKey}:${request.shadeKey}',
      );
    } else if (request is FoundationLookRequest) {
      await _applyHarmonyLook(request);
    }
  }

  // ── OVERLAY PUSH HELPER ──────────────────────────────────────────────────
  //
  // 🆕 FIX v2 (real root cause of the black-screen / "disconnected/abandoned
  // window" / EGL_BAD_NATIVE_WINDOW loop after Sign-In):
  //
  // A previous fix tried pushing AuthScreen/ProfileScreen/SavedLooksScreen
  // as a NON-OPAQUE route on the ROOT Navigator, hoping that would stop
  // Flutter from offstaging TryOnScreen. That was not enough: DeepAR's
  // `SurfaceView` is embedded via hybrid composition relative to the ROOT
  // Navigator's `Overlay`. Pushing or popping ANY route on that Navigator —
  // opaque or not — makes Android recompute the Android view hierarchy's
  // z-order/compositing above the SurfaceView. On this device's GPU
  // (PowerVR/MediaTek) that recompute is exactly what makes Android
  // invalidate/abandon the SurfaceView's native `Surface`, regardless of
  // the pushed route's opacity.
  //
  // The real fix is to never push these screens onto the root Navigator at
  // all. Instead they go onto `_overlayNavKey` — a separate Navigator that
  // lives inside TryOnScreen's OWN widget tree (see the OVERLAY NAVIGATOR
  // widget in build()). Because it is a completely different Navigator/
  // Overlay from the one the root app uses, pushing or popping routes on it
  // never touches the root Overlay, so DeepAR's SurfaceView is never
  // disturbed. AuthScreen/ProfileScreen/SavedLooksScreen need ZERO changes
  // for this to work — `Navigator.of(context)` / `Navigator.pop(context)`
  // called from inside them automatically resolves to the nearest Navigator
  // ancestor, which is this nested one, not the root.
  Future<T?> _pushOverlay<T>(Widget page) async {
    if (!mounted) return null;
    setState(() => _overlayActive = true);
    final result = await _overlayNavKey.currentState!.push<T>(
      MaterialPageRoute<T>(builder: (_) => page),
    );
    // Rebind while _overlayActive is still true so a late `resumed` event
    // cannot start a second DeepAR init over this one.
    if (mounted) await _resumeDeepArAfterPluginCamera();
    if (mounted) setState(() => _overlayActive = false);
    return result;
  }

  /// The foundation capture screen uses the `camera` plugin, which calls
  /// CameraX `unbindAll()`. DeepAR's preview texture keeps its last frame
  /// and never gets those frames back. `start_camera` rebinds the existing
  /// DeepAR session. It does not create another one.
  Future<void> _resumeDeepArAfterPluginCamera() async {
    if (!FoundationCaptureScreen.cameraPluginTookDevice) return;
    if (!mounted || _cameraRebindInFlight || _initInProgress || _reinitCycleActive) {
      return;
    }
    if (!_isInitialized) {
      // Still starting: leave the flag so the end of that cycle rebinds.
      // Already failed: Try again opens a new camera, so drop the flag.
      if (!_initInProgress && !_reinitCycleActive) {
        FoundationCaptureScreen.cameraPluginTookDevice = false;
      }
      return;
    }

    FoundationCaptureScreen.cameraPluginTookDevice = false;
    _cameraRebindInFlight = true;
    _lastReinitAt = DateTime.now();
    try {
      if (!Platform.isAndroid) {
        _giveUpOnCamera('camera feed was not resumed');
        return;
      }
      await const MethodChannel('deep_ar/camerax')
          .invokeMethod<dynamic>('start_camera')
          .timeout(const Duration(seconds: 8));
      debugPrint('DeepAR: camera feed resumed after foundation capture');
      if (mounted) setState(() => _surfaceReady = true);
    } catch (e) {
      debugPrint('DeepAR: camera resume failed: $e');
      _giveUpOnCamera('camera feed did not resume');
    } finally {
      _cameraRebindInFlight = false;
    }
  }

  // ── DEEP AR INIT ──────────────────────────────────────────────────────────

  // ── DEEPAR INIT ───────────────────────────────────────────────────────────
  //
  // Uses _initInProgress flag to prevent concurrent calls (lifecycle races).
  // Retries up to 3 times with exponential back-off.
  // Shows a retry dialog on total failure.
  //
  Future<void> _initializeDeepAR() async {
    // Guard: only proceed if surface is ready and no other init in progress
    if (!_surfaceReady || _initInProgress || !mounted) return;
    _initInProgress = true;

    // 🔧 Controller is fresh (just created in lifecycle or at startup)
    // No need to destroy it again — just initialize
    if (_isInitialized) {
      // Should not happen since we destroy on pause, but safety check
      debugPrint('DeepAR: already initialized, skipping reinit');
      _initInProgress = false;
      return;
    }

    const maxAttempts = 3;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      if (!mounted) {
        _initInProgress = false;
        return;
      }
      debugPrint('DeepAR: init attempt $attempt/$maxAttempts');

      try {
        final started = await _deepArController
            .initialize(
              androidLicenseKey: androidKey,
              iosLicenseKey: iosKey,
              resolution: Resolution.high,
            )
            .timeout(const Duration(seconds: 8));

        if (started != true) {
          _initInProgress = false;
          if (mounted) {
            setState(() {
              _isInitialized = false;
              _initFailed = true;
              _cameraAccessOff = true;
            });
          }
          return;
        }

        if (!mounted) {
          _initInProgress = false;
          return;
        }

        await _deepArController
            .switchEffect('assets/effects/makeup.deepar')
            .timeout(const Duration(seconds: 8));

        if (!mounted) {
          _initInProgress = false;
          return;
        }

        if (mounted) {
          setState(() {
            _isInitialized = true;
            _initFailed = false;
            _cameraAccessOff = false;
          });
        }

        // Restore previously selected shades
        for (var cat in TryOnCategory.values) {
          if (_selectedShades[cat] != null) {
            await _applyColorToDeepAR(_selectedShades[cat], cat);
          }
        }

        _panelController.forward();
        _topBarController.forward();
        _initInProgress = false;
        _initWatchdog?.cancel();
        unawaited(_applyInitialRequest());
        debugPrint('DeepAR: ready ✓');
        return;
      } catch (e) {
        debugPrint('DeepAR: attempt $attempt failed: $e');

        // If init failed, wait and retry with same controller
        if (attempt < maxAttempts && mounted) {
          // Exponential backoff before retry
          await Future.delayed(Duration(milliseconds: 600 * attempt));
        }
      }
    }

    _initInProgress = false;
    if (mounted) setState(() => _initFailed = true);
  }

  // ── DB LOAD ───────────────────────────────────────────────────────────────

  Future<void> _loadDataFromDb() async {
    final disk = await _loadShadesFromCache();
    final shadesAreFresh = disk.isFreshAt(DateTime.now()) && disk.shades.isNotEmpty;

    if (!shadesAreFresh) {
    try {
      final shadeRes = await Supabase.instance.client
          .from('product_shades')
          .select()
          .order('shade_order', ascending: true)
          .timeout(const Duration(seconds: 12));
      final allFetched = (shadeRes as List<dynamic>)
          .map((e) => DbShade.fromMap(e))
          .toList();
      // Deduplicate by productKey + hex
      final uniqueShades = <String, DbShade>{};
      for (var shade in allFetched) {
        final key = '${shade.productKey}_${shade.shadeHex}';
        uniqueShades.putIfAbsent(key, () => shade);
      }
      if (mounted) {
        setState(() {
          _allDbShades = uniqueShades.values.toList();
          _shadeLoadSettled = true;
          _shadeLoadError = null;
        });
      }

      await _saveShadesToCache(
        uniqueShades.values.map((shade) {
          return {
            'product_key': shade.productKey,
            'shade_key': shade.shadeKey,
            'shade_name': shade.shadeName,
            'shade_hex': shade.shadeHex,
            'shade_order': shade.shadeOrder,
          };
        }).toList(),
      );
    } catch (e) {
      debugPrint('❌ Error loading shades: $e');
      if (mounted && _allDbShades.isEmpty) {
        setState(() {
          _shadeLoadSettled = true;
          _shadeLoadError = 'Shades did not load. Check your connection and try again.';
        });
      } else if (mounted) {
        setState(() => _shadeLoadSettled = true);
      }
    }
    }

    try {
      final lashRes = await Supabase.instance.client
          .from('ar_lash_configs')
          .select()
          .timeout(const Duration(seconds: 10));
      final configsMap = <String, DbLashConfig>{};
      for (var row in (lashRes as List<dynamic>)) {
        final config = DbLashConfig.fromMap(row);
        configsMap[config.productKey] = config;
      }
      if (mounted) {
        setState(() {
          _lashConfigs = configsMap;
          _lashConfigsSettled = true;
        });
      }
    } catch (e) {
      debugPrint('❌ Error loading lash configs: $e');
      if (mounted) setState(() => _lashConfigsSettled = true);
    }
  }

  // ── ASSET HELPER (cached) ─────────────────────────────────────────────────

  Future<String> _getAssetPath(String assetName) async {
    if (_assetPathCache.containsKey(assetName)) {
      return _assetPathCache[assetName]!;
    }
    final byteData = await rootBundle.load('assets/textures/$assetName');
    final file = File('${(await getTemporaryDirectory()).path}/$assetName');
    await file.writeAsBytes(
      byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      ),
    );
    _assetPathCache[assetName] = file.path;
    return file.path;
  }

  // ── LOGIN PROMPT ──────────────────────────────────────────────────────────

  void _showLoginPrompt(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(message, style: const TextStyle(color: Colors.white)),
            ),
            TextButton(
              onPressed: () async {
                messenger.clearSnackBars();

                if (!mounted) return;

                // 🆕 FIX: Do NOT destroy/reinitialize DeepAR for plain
                // in-app navigation anymore. The deepar_flutter (0.0.5)
                // plugin has no pause()/resume() API — the only "pause"
                // mechanism available at the Flutter level was a full
                // destroy() + initialize() cycle. On this device's GPU
                // (PowerVR / MediaTek), that explicit reinit cycle itself
                // crashes natively inside bgfx during the very first
                // initialize() attempt (SIGABRT in
                // bgfx::gl::GlContext::resize, right after
                // "IsTextureConsistent: IMGEGLImage is not consistent"),
                // even when there's no double-init race. So instead of
                // tearing the controller down, we simply leave TryOnScreen
                // (and its DeepArPreview) mounted underneath AuthScreen.
                // Its State — and the native camera session — stays alive
                // while AuthScreen is on top, and reappears instantly with
                // no reinit and no black screen when the user comes back.
                //
                // 🆕 FIX v2: pushed onto the nested overlay Navigator via
                // _pushOverlay() instead of the root Navigator — this is
                // the flow that goes through this exact snackbar (Save/
                // Favourite → "Sign in to ..." → tap "Sign In") and was
                // producing the black screen / abandoned-Surface loop.
                // The root Navigator/Overlay (and DeepAR's SurfaceView
                // composited relative to it) is never touched.
                await _pushOverlay<void>(const AuthScreen(isLoginMode: true));
                // Nothing to reinitialize — DeepAR was never torn down.
              },
              child: const Text(
                'Sign In',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
            ),
          ],
        ),
        backgroundColor: AppColors.primary,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(
          seconds: 4,
        ), // Thoda extra time taake user click kar sake
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.only(left: 16, right: 8),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  // ── APPLY COLOR ───────────────────────────────────────────────────────────
  //
  // _intensities[category] is the USER'S 0.0–1.0 value (shown as 0–100 % in UI).
  // Before sending to DeepAR we ALWAYS call _mapIntensityToBackend() which
  // remaps to the physically realistic range for that product category.
  //
  Future<void> _applyColorToDeepAR(
    DbShade? shade,
    TryOnCategory category,
  ) async {
    if (!_isInitialized) return;
    final gameObject = _getGameObject(category);

    // ── CLEAR / NULL ──────────────────────────────────────────────────────
    if (shade == null) {
      if (category == TryOnCategory.foundation) {
        _deepArController.changeParameter(
          gameObject: gameObject,
          component: 'MeshRenderer',
          parameter: 'foundationColor',
          newParameter: vector.Vector4(0.9, 0.88, 0.80, 0.0),
        );
      } else if (category == TryOnCategory.lipstick ||
          category == TryOnCategory.lipGloss) {
        for (final param in [
          'u_diffuseColor',
          'u_ambientColor',
          'u_specularColor',
        ]) {
          _deepArController.changeParameter(
            gameObject: gameObject,
            component: 'MeshRenderer',
            parameter: param,
            newParameter: vector.Vector4(0, 0, 0, 0),
          );
        }
        _deepArController.changeParameter(
          gameObject: gameObject,
          component: 'MeshRenderer',
          parameter: 'u_shininess',
          newParameter: 0.0,
        );
      } else {
        _deepArController.changeParameter(
          gameObject: gameObject,
          component: 'MeshRenderer',
          parameter: 'u_color',
          newParameter: vector.Vector4(0, 0, 0, 0),
        );
      }
      return;
    }

    if (_isHighlighter(category: category, productKey: shade.productKey)) {
      return;
    }

    final color = shade.color;
    final r = color.red / 255.0;
    final g = color.green / 255.0;
    final b = color.blue / 255.0;

    final userIntensity = _intensities[category] ?? 0.5;
    final backendIntensity = _mapIntensityToBackend(category, userIntensity);

    // ── EYELASHES / MASCARA ───────────────────────────────────────────────
    if (category == TryOnCategory.eyelashes ||
        category == TryOnCategory.mascara) {
      final config = _lashConfigs[shade.productKey];
      if (config != null) {
        try {
          final textureName = config.baseMaskType == 'gorgeous'
              ? 'gorgeous.png'
              : 'sexy.png';
          final texturePath = await _getAssetPath(textureName);
          _deepArController.changeParameter(
            gameObject: gameObject,
            component: 'MeshRenderer',
            parameter: 's_texColor',
            newParameter: texturePath,
          );
          _deepArController.changeParameter(
            gameObject: gameObject,
            component: 'Transform',
            parameter: 'scale',
            newParameter: vector.Vector3(config.scaleX, config.scaleY, 1.0),
          );
          final lashColor = config.color;
          final finalAlpha = (config.opacity * backendIntensity).clamp(
            0.0,
            1.0,
          );
          _deepArController.changeParameter(
            gameObject: gameObject,
            component: 'MeshRenderer',
            parameter: 'u_color',
            newParameter: vector.Vector4(
              lashColor.red / 255.0,
              lashColor.green / 255.0,
              lashColor.blue / 255.0,
              finalAlpha,
            ),
          );
        } catch (e) {
          debugPrint('❌ Failed to apply Lash Config: $e');
        }
      }
      return;
    }

    // ── FOUNDATION ────────────────────────────────────────────────────────
    //
    // backendIntensity range: 0.12 → 0.44
    // Passed directly as alpha — keeps coverage skin-blended always.
    //
    if (category == TryOnCategory.foundation) {
      try {
        _deepArController.changeParameter(
          gameObject: gameObject,
          component: 'MeshRenderer',
          parameter: 'foundationColor',
          newParameter: vector.Vector4(r, g, b, backendIntensity),
        );
      } catch (e) {
        debugPrint('❌ Foundation apply failed: $e');
      }
      return;
    }

    // ── LIPSTICK ──────────────────────────────────────────────────────────
    //
    // Semi-matte physics:
    //   Ambient 0.40  — colour fills shadow areas
    //   Diffuse alpha: backendIntensity (0.30 → 0.68)
    //   Specular (0.08, 0.08, 0.09) — very subtle; lipstick is not shiny
    //   Shininess 18  — wide soft lobe = satin (not glass / plastic)
    //
    if (category == TryOnCategory.lipstick) {
      try {
        _deepArController.changeParameter(
          gameObject: gameObject,
          component: 'MeshRenderer',
          parameter: 'u_ambientColor',
          newParameter: vector.Vector4(0.40, 0.40, 0.40, 1.0),
        );
        _deepArController.changeParameter(
          gameObject: gameObject,
          component: 'MeshRenderer',
          parameter: 'u_diffuseColor',
          newParameter: vector.Vector4(r, g, b, backendIntensity),
        );
        _deepArController.changeParameter(
          gameObject: gameObject,
          component: 'MeshRenderer',
          parameter: 'u_specularColor',
          newParameter: vector.Vector4(0.08, 0.08, 0.09, 1.0),
        );
        _deepArController.changeParameter(
          gameObject: gameObject,
          component: 'MeshRenderer',
          parameter: 'u_shininess',
          newParameter: 18.0,
        );
      } catch (e) {
        debugPrint('❌ Lipstick apply failed: $e');
      }
      return;
    }

    // ── LIP GLOSS ─────────────────────────────────────────────────────────
    //
    // Glossy physics:
    //   Diffuse alpha: backendIntensity (0.38 → 0.60) — low = translucency
    //   Ambient 0.55  — enough fill to show tint in shadow
    //   Specular (0.85, 0.87, 0.90) near-white, blue-shifted = "wet" look
    //   Shininess 72  — tight but not glass-like
    //
    if (category == TryOnCategory.lipGloss) {
      try {
        _deepArController.changeParameter(
          gameObject: gameObject,
          component: 'MeshRenderer',
          parameter: 'u_ambientColor',
          newParameter: vector.Vector4(0.55, 0.55, 0.55, 1.0),
        );
        _deepArController.changeParameter(
          gameObject: gameObject,
          component: 'MeshRenderer',
          parameter: 'u_diffuseColor',
          newParameter: vector.Vector4(r, g, b, backendIntensity),
        );
        _deepArController.changeParameter(
          gameObject: gameObject,
          component: 'MeshRenderer',
          parameter: 'u_specularColor',
          newParameter: vector.Vector4(0.85, 0.87, 0.90, 1.0),
        );
        _deepArController.changeParameter(
          gameObject: gameObject,
          component: 'MeshRenderer',
          parameter: 'u_shininess',
          newParameter: 72.0,
        );
      } catch (e) {
        debugPrint('❌ Lip Gloss apply failed: $e');
      }
      return;
    }

    // ── EYESHADOW / EYELINER / BLUSH / HIGHLIGHTER ────────────────────────
    // backendIntensity is the physically correct alpha for each category.
    try {
      _deepArController.changeParameter(
        gameObject: gameObject,
        component: 'MeshRenderer',
        parameter: 'u_color',
        newParameter: vector.Vector4(r, g, b, backendIntensity),
      );
    } catch (e) {
      debugPrint('❌ Apply failed for $gameObject: $e');
    }
  }

  // ── BARE FACE AND SHADE COMPARE ──────────────────────────────────────────

  Future<void> _deleteShot(File? file) async {
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('temp screenshot delete failed: $e');
    }
  }

  Future<void> _settleFrame() => Future<void>.delayed(const Duration(milliseconds: 280));

  Future<bool> _clearSelectedMakeup() async {
    if (!_isInitialized) return false;
    try {
      for (final entry in _selectedShades.entries) {
        if (entry.value != null) {
          await _applyColorToDeepAR(null, entry.key);
        }
      }
      return _isInitialized;
    } catch (e) {
      debugPrint('bare-face clear failed: $e');
      return false;
    }
  }

  Future<void> _reapplySelectedShades() async {
    for (final entry in _selectedShades.entries) {
      if (entry.value != null) {
        await _applyColorToDeepAR(entry.value, entry.key);
      }
    }
  }

  Future<void> _beginBareHold() async {
    if (_bareHoldActive || _compareOpen || _shadeCaptureBusy) return;
    if (_rejectFrameCapture(allowed: _faceGuidance.canHold)) return;
    if (!_selectedShades.values.any((shade) => shade != null)) {
      _showSnack('Apply a shade first.');
      return;
    }
    if (!_isInitialized) {
      await _openBareStills();
      return;
    }
    final token = ++_bareToken;
    _bareHoldActive = true;
    if (mounted) setState(() {});
    final cleared = await _clearSelectedMakeup();
    if (!mounted || token != _bareToken || !_bareHoldActive) {
      if (cleared) await _reapplySelectedShades();
      return;
    }
    if (!cleared) {
      _bareHoldActive = false;
      if (mounted) setState(() {});
      await _openBareStills();
    }
  }

  void _endBareHold() {
    if (!_bareHoldActive) return;
    _bareHoldActive = false;
    _bareToken++;
    if (mounted) setState(() {});
    _reapplySelectedShades();
  }

  Future<File?> _takeShot() async {
    try {
      final file = await _deepArController.takeScreenshot();
      if (!await file.exists()) return null;
      return file;
    } catch (e) {
      debugPrint('screenshot failed: $e');
      return null;
    }
  }

  Future<void> _openBareStills() async {
    if (_shadeCaptureBusy || _compareOpen) return;
    if (_rejectFrameCapture(allowed: _faceGuidance.canHold)) return;
    if (!_isInitialized) {
      _showSnack('Could not capture a bare-face photo.');
      return;
    }
    _shadeCaptureBusy = true;
    File? withMakeup;
    File? bare;
    try {
      withMakeup = await _takeShot();
      final cleared = await _clearSelectedMakeup();
      if (withMakeup == null || !cleared) {
        await _deleteShot(withMakeup);
        await _reapplySelectedShades();
        _showSnack('Could not capture a bare-face photo.');
        return;
      }
      await _settleFrame();
      if (_rejectFrameCapture(allowed: _faceGuidance.canHold)) {
        await _deleteShot(withMakeup);
        await _reapplySelectedShades();
        return;
      }
      bare = await _takeShot();
      await _reapplySelectedShades();
      if (bare == null) {
        await _deleteShot(withMakeup);
        _showSnack('Could not capture a bare-face photo.');
        return;
      }
      await _presentCompare(
        left: withMakeup,
        right: bare,
        leftLabel: 'With makeup',
        rightLabel: 'Bare face',
        choosesShade: false,
      );
    } catch (e) {
      debugPrint('bare stills failed: $e');
      await _deleteShot(withMakeup);
      await _deleteShot(bare);
      await _reapplySelectedShades();
      _showSnack('Could not capture a bare-face photo.');
    } finally {
      _shadeCaptureBusy = false;
    }
  }

  void _startShadeCompare(TryOnCategory category) {
    if (_shadeCaptureBusy || _compareOpen) return;
    if (_rejectFrameCapture(allowed: _faceGuidance.canCapture)) return;
    final available = _allDbShades
        .where((shade) => shade.productKey.startsWith(_prefixFor(category)))
        .length;
    if (available < 2) {
      _showSnack('This category needs two shades to compare.');
      return;
    }
    setState(() {
      _currentCategory = category;
      _comparePickCategory = category;
      _comparePicking = true;
      _comparePicks.clear();
      _shadeBeforeCompare = _selectedShades[category];
      _demoStatus = 'Tap two ${_getCategoryName(category).toLowerCase()} shades.';
    });
  }

  void _cancelShadeComparePick() {
    final category = _comparePickCategory;
    final previous = _shadeBeforeCompare;
    setState(() {
      _comparePicking = false;
      _comparePicks.clear();
      _demoStatus = null;
      _selectedShades[category] = previous;
      _shadeBeforeCompare = null;
    });
    _applyColorToDeepAR(previous, category);
  }

  Future<void> _onCompareShadeTapped(DbShade shade) async {
    if (!_comparePicking || _shadeCaptureBusy) return;
    final already = _comparePicks.any(
      (picked) => picked.productKey == shade.productKey && picked.shadeKey == shade.shadeKey,
    );
    if (already) {
      _showSnack('Pick a different second shade.');
      return;
    }
    if (_comparePicks.isNotEmpty &&
        _rejectFrameCapture(allowed: _faceGuidance.canCapture)) {
      return;
    }
    setState(() {
      _comparePicks.add(shade);
      _selectedShades[_comparePickCategory] = shade;
      _demoStatus = _comparePicks.length == 1
          ? 'Tap the second shade.'
          : 'Capturing both shades…';
    });
    await _applyColorToDeepAR(shade, _comparePickCategory);
    if (_comparePicks.length < 2) return;
    final first = _comparePicks[0];
    final second = _comparePicks[1];
    setState(() => _comparePicking = false);
    await _captureShadePair(_comparePickCategory, first, second);
  }

  Future<void> _captureShadePair(
    TryOnCategory category,
    DbShade shadeA,
    DbShade shadeB,
  ) async {
    final previous = _shadeBeforeCompare;
    if (_rejectFrameCapture(allowed: _faceGuidance.canCapture)) {
      await _restoreShade(category, previous);
      if (mounted) {
        setState(() {
          _comparePicks.clear();
          _demoStatus = null;
        });
      }
      return;
    }
    if (!_isInitialized) {
      _showSnack("Couldn't capture those shades. Back on the camera.");
      return;
    }
    _shadeCaptureBusy = true;
    File? fileA;
    File? fileB;
    try {
      setState(() {
        _currentCategory = category;
        _selectedShades[category] = shadeA;
      });
      await _applyColorToDeepAR(shadeA, category);
      await _settleFrame();
      if (_rejectFrameCapture(allowed: _faceGuidance.canCapture)) {
        await _restoreShade(category, previous);
        return;
      }
      fileA = await _takeShot();
      if (fileA == null) {
        await _restoreShade(category, previous);
        _showSnack("Couldn't capture those shades. Back on the camera.");
        return;
      }
      setState(() => _selectedShades[category] = shadeB);
      await _applyColorToDeepAR(shadeB, category);
      await _settleFrame();
      if (_rejectFrameCapture(allowed: _faceGuidance.canCapture)) {
        await _deleteShot(fileA);
        await _restoreShade(category, previous);
        return;
      }
      fileB = await _takeShot();
      if (fileB == null) {
        await _deleteShot(fileA);
        await _restoreShade(category, previous);
        _showSnack("Couldn't capture those shades. Back on the camera.");
        return;
      }
      _compareShadeA = shadeA;
      _compareShadeB = shadeB;
      _compareShadeCategory = category;
      await _presentCompare(
        left: fileA,
        right: fileB,
        leftLabel: shadeA.shadeName,
        rightLabel: shadeB.shadeName,
        choosesShade: true,
      );
    } catch (e) {
      debugPrint('shade compare failed: $e');
      await _deleteShot(fileA);
      await _deleteShot(fileB);
      await _restoreShade(category, previous);
      _showSnack("Couldn't capture those shades. Back on the camera.");
    } finally {
      _shadeCaptureBusy = false;
      if (mounted) {
        setState(() {
          _comparePicks.clear();
          if (!_compareOpen) _demoStatus = null;
        });
      }
    }
  }

  Future<void> _restoreShade(TryOnCategory category, DbShade? shade) async {
    if (!mounted) return;
    setState(() => _selectedShades[category] = shade);
    await _applyColorToDeepAR(shade, category);
  }

  Future<void> _presentCompare({
    required File left,
    required File right,
    required String leftLabel,
    required String rightLabel,
    required bool choosesShade,
  }) async {
    final leftBytes = await left.readAsBytes();
    final rightBytes = await right.readAsBytes();
    if (!mounted) {
      await _deleteShot(left);
      await _deleteShot(right);
      return;
    }
    setState(() {
      _compareLeftFile = left;
      _compareRightFile = right;
      _compareLeftBytes = leftBytes;
      _compareRightBytes = rightBytes;
      _compareLeftLabel = leftLabel;
      _compareRightLabel = rightLabel;
      _compareChoosesShade = choosesShade;
      _compareSplit = 0.5;
      _compareOpen = true;
      _demoStatus = null;
    });
  }

  Future<void> _closeCompare({required bool useWinner}) async {
    final category = _compareShadeCategory;
    final shadeA = _compareShadeA;
    final shadeB = _compareShadeB;
    final previous = _shadeBeforeCompare;
    final split = _compareSplit;
    final chooses = _compareChoosesShade;
    final left = _compareLeftFile;
    final right = _compareRightFile;
    if (mounted) {
      setState(() {
        _compareOpen = false;
        _compareLeftBytes = null;
        _compareRightBytes = null;
        _compareLeftFile = null;
        _compareRightFile = null;
        _compareShadeA = null;
        _compareShadeB = null;
        _compareShadeCategory = null;
        _shadeBeforeCompare = null;
        _demoStatus = null;
      });
    }
    await _deleteShot(left);
    await _deleteShot(right);
    if (!chooses || category == null || shadeA == null || shadeB == null) return;
    final winner = compareWinner(
      CatalogShade(
        productKey: shadeA.productKey,
        shadeKey: shadeA.shadeKey,
        shadeName: shadeA.shadeName,
        shadeHex: shadeA.shadeHex,
      ),
      CatalogShade(
        productKey: shadeB.productKey,
        shadeKey: shadeB.shadeKey,
        shadeName: shadeB.shadeName,
        shadeHex: shadeB.shadeHex,
      ),
      split,
    );
    final chosen = winner.shadeKey == shadeA.shadeKey && winner.productKey == shadeA.productKey
        ? shadeA
        : shadeB;
    if (useWinner) {
      await _restoreShade(category, chosen);
      _showSnack('Using ${chosen.shadeName}.');
    } else {
      await _restoreShade(category, previous);
    }
  }

  Future<void> _applyHarmonyLook(FoundationLookRequest request) async {
    if (_allDbShades.isEmpty) {
      await _loadDataFromDb();
      if (!mounted) return;
    }
    final maps = _allDbShades
        .map((shade) => {
              'product_key': shade.productKey,
              'shade_key': shade.shadeKey,
              'shade_name': shade.shadeName,
              'shade_hex': shade.shadeHex,
            })
        .toList();
    final items = <Map<String, dynamic>>[];
    final names = <String>[];
    var skipped = 0;

    void addIfPresent(String productKey, String shadeKey, int intensity, String label) {
      final match = _allDbShades.where(
        (shade) => shade.productKey == productKey && shade.shadeKey == shadeKey,
      );
      if (match.isEmpty) {
        skipped++;
        return;
      }
      items.add({
        'product_key': productKey,
        'shade_key': shadeKey,
        'intensity': intensity,
      });
      names.add('$label ${match.first.shadeName}');
    }

    addIfPresent(
      request.productKey,
      request.shadeKey,
      ((_intensities[TryOnCategory.foundation] ?? 0.4) * 100).round(),
      'Foundation',
    );

    final blushShades = maps.where((row) => row['product_key']!.startsWith('blu_')).toList();
    var lipShades = maps.where((row) => row['product_key']!.startsWith('lip_')).toList();
    if (lipShades.isEmpty) {
      lipShades = maps.where((row) => row['product_key']!.startsWith('gloss_')).toList();
    }
    final blush = nearestHarmonyShade(
      shades: blushShades,
      skinHex: request.skinHex,
      undertone: request.undertone,
      lip: false,
    );
    final lip = nearestHarmonyShade(
      shades: lipShades,
      skinHex: request.skinHex,
      undertone: request.undertone,
      lip: true,
    );
    if (blush == null) {
      skipped++;
    } else {
      addIfPresent(
        blush.productKey,
        blush.shadeKey,
        ((_intensities[TryOnCategory.blush] ?? 0.52) * 100).round(),
        'Blush',
      );
    }
    if (lip == null) {
      skipped++;
    } else {
      addIfPresent(
        lip.productKey,
        lip.shadeKey,
        ((_intensities[TryOnCategory.lipstick] ?? 0.65) * 100).round(),
        'Lip',
      );
    }

    if (items.isEmpty) {
      _showSnack("Those products aren't in the catalog.");
      return;
    }
    final skippedNote = skipped == 0
        ? ''
        : ' Skipped $skipped product${skipped == 1 ? '' : 's'} that ${skipped == 1 ? 'is' : 'are'} not in the catalog.';
    _loadAndApplySavedLook(
      items,
      note: '${names.join(', ')}.$skippedNote',
    );
  }

  List<WearOrderLine> _wearLinesForCurrentLook() {
    final items = <Map<String, dynamic>>[];
    var layer = 1;
    for (final entry in _selectedShades.entries) {
      final shade = entry.value;
      if (shade == null) continue;
      items.add({
        'product_key': shade.productKey,
        'shade_key': shade.shadeKey,
        'shade_name': shade.shadeName,
        'intensity': ((_intensities[entry.key] ?? 0.5) * 100).round(),
        'layer_order': layer++,
      });
    }
    return wearOrderForItems(
      items,
      titleFor: (item) {
        final key = item['product_key']?.toString() ?? '';
        final product = ProductsCache.instance.byKey(key)?.name.trim();
        if (product != null && product.isNotEmpty) return product;
        final shadeName = item['shade_name']?.toString().trim();
        if (shadeName != null && shadeName.isNotEmpty) return shadeName;
        return null;
      },
    );
  }

  // ── LOAD SAVED LOOK ───────────────────────────────────────────────────────

  void _loadAndApplySavedLook(List<dynamic> items, {String? note}) {
    // Batch all state mutations into a single setState
    final Map<TryOnCategory, DbShade?> newShades = {
      for (var cat in TryOnCategory.values) cat: null,
    };
    final Map<TryOnCategory, double> newIntensities = Map.from(_intensities);

    // Clear AR first
    for (var cat in TryOnCategory.values) {
      _applyColorToDeepAR(null, cat);
    }

    var skippedHighlighter = false;
    for (var item in items) {
      final productKey = item['product_key'] as String;
      final shadeKey = item['shade_key'] as String;
      // DB stores 0–100; convert to 0.0–1.0 for slider
      final intensity = (item['intensity'] as num).toDouble() / 100.0;

      final prefix = _prefixForKey(productKey);
      final cat = _categoryForPrefix(prefix);
      if (_isHighlighter(category: cat, productKey: productKey)) {
        skippedHighlighter = true;
        continue;
      }
      if (cat == null) {
        debugPrint('⚠️ Unknown product prefix: $productKey');
        continue;
      }

      try {
        final shade = _allDbShades.firstWhere(
          (s) => s.productKey == productKey && s.shadeKey == shadeKey,
        );
        newShades[cat] = shade;
        newIntensities[cat] = intensity;
        _applyColorToDeepAR(shade, cat);
      } catch (_) {
        debugPrint('⚠️ Shade not found: $productKey - $shadeKey');
      }
    }

    setState(() {
      for (var cat in TryOnCategory.values) {
        _selectedShades[cat] = newShades[cat];
        _intensities[cat] = newIntensities[cat]!;
      }
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          skippedHighlighter
              ? "Highlighter isn't in this effect."
              : (note ?? '✨ Look applied!'),
          style: const TextStyle(color: Colors.white),
        ),
        backgroundColor: AppColors.primary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ── SAVE LOOK ─────────────────────────────────────────────────────────────

  Future<void> _saveLookToDb(String lookName) async {
    final block = _faceBlockReason();
    if (block != null) {
      _showSnack(block);
      return;
    }
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Please sign in to save looks.',
            style: TextStyle(color: Colors.white),
          ),
          backgroundColor: AppColors.primary,
        ),
      );
      return;
    }
    if (!_selectedShades.values.any((s) => s != null)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Please apply some makeup first!',
            style: TextStyle(color: Colors.white),
          ),
          backgroundColor: AppColors.primary,
        ),
      );
      return;
    }

    await _processPendingSavedLooks();

    final trimmedLookName = lookName.trim().isEmpty
        ? 'My Custom Look'
        : lookName.trim();

    final List<Map<String, dynamic>> itemsToInsert = [];
    int layerOrder = 1;
    for (var entry in _selectedShades.entries) {
      final shade = entry.value;
      if (shade != null) {
        itemsToInsert.add({
          'product_key': shade.productKey,
          'shade_key': shade.shadeKey,
          'intensity': ((_intensities[entry.key] ?? 0.5) * 100).toInt(),
          'layer_order': layerOrder++,
        });
      }
    }

    File? previewFile = _saveDialogScreenshotFile;
    if (previewFile == null) {
      try {
        previewFile = await _deepArController.takeScreenshot();
      } catch (e) {
        debugPrint('❌ Screenshot capture failed: $e');
      }
    }

    if (previewFile == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Unable to capture preview for save.',
              style: TextStyle(color: Colors.white),
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      return;
    }

    // Show optimistic "Saving..." toast
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            '📸 Saving your look...',
            style: TextStyle(color: Colors.white),
          ),
          backgroundColor: AppColors.primary,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.all(16),
          duration: const Duration(seconds: 5),
        ),
      );
    }

    try {
      String? previewUrl;
      final fileName = '${userId}_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final bytes = await previewFile.readAsBytes();
      await Supabase.instance.client.storage
          .from('looks')
          .uploadBinary(fileName, bytes);
      previewUrl = Supabase.instance.client.storage
          .from('looks')
          .getPublicUrl(fileName);

      final lookRes = await Supabase.instance.client
          .from('saved_looks')
          .insert({
            'user_id': userId,
            'look_name': trimmedLookName,
            'preview_image_url': previewUrl,
          })
          .select('id')
          .single();
      final lookId = lookRes['id'].toString();

      final itemsWithLook = itemsToInsert
          .map((entry) => {...entry, 'look_id': lookId})
          .toList();

      if (itemsWithLook.isNotEmpty) {
        await Supabase.instance.client
            .from('saved_look_items')
            .insert(itemsWithLook);
      }

      final newLook = {
        'id': lookId,
        'user_id': userId,
        'look_name': trimmedLookName,
        'preview_image_url': previewUrl,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'is_favourite': false,
      };
      LooksCache.instance.optimisticAdd(newLook);
      try {
        await LooksCache.instance.refresh(userId);
      } catch (e) {
        debugPrint('❌ LooksCache refresh after save failed: $e');
      }

      if (!mounted) return;
      // Dialog already closed, just show success toast
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            '✨ Look saved! 💖',
            style: TextStyle(color: Colors.white),
          ),
          backgroundColor: AppColors.primary,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.all(16),
        ),
      );

      // Wear order, then the existing buy sheet. No second cart button.
      _showBuyThisLookSheet(
        lookId,
        trimmedLookName,
        itemsToInsert,
        _wearLinesForCurrentLook(),
      );
    } catch (e) {
      debugPrint('❌ Save failed, queuing locally: $e');
      try {
        await _queueLookForLater(
          userId,
          trimmedLookName,
          previewFile,
          itemsToInsert,
        );
        if (!mounted) return;
        _showWearOrderOnly(_wearLinesForCurrentLook());
        // Dialog already closed, show offline save toast
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              '📱 Saved locally. Will sync when online.',
              style: TextStyle(color: Colors.white),
            ),
            backgroundColor: AppColors.primary,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            margin: const EdgeInsets.all(16),
          ),
        );
      } catch (queueError) {
        debugPrint('❌ Failed to queue offline save: $queueError');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed: $queueError'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  // ── SAVE DIALOG ───────────────────────────────────────────────────────────

  Future<void> _showSaveLookDialog() async {
    final block = _faceBlockReason();
    if (block != null) {
      _showSnack(block);
      return;
    }
    final nameController = TextEditingController();
    if (!mounted) return;

    setState(() => _isSaveDialogOpen = true);

    // Start screenshot capture in background (don't wait for it)
    // This makes the dialog appear faster
    _captureFreezeFrame();

    if (!mounted) {
      await _clearSaveDialogFreeze();
      return;
    }

    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.60),
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(32),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: AppColors.surface.withValues(alpha: 0.96),
                borderRadius: BorderRadius.circular(32),
                border: Border.all(color: AppColors.border, width: 1),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          Icons.bookmark_add_rounded,
                          color: AppColors.primary,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Save Your Look',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                color: AppColors.textMain,
                                letterSpacing: -0.4,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Give it a name to find it later',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: AppColors.textMuted,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Container(
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.border, width: 1.2),
                    ),
                    child: TextField(
                      controller: nameController,
                      style: TextStyle(
                        color: AppColors.textMain,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                      decoration: InputDecoration(
                        hintText: 'E.g. Glam Night, Everyday Nude…',
                        hintStyle: TextStyle(
                          color: AppColors.textMuted,
                          fontWeight: FontWeight.w400,
                        ),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 15,
                        ),
                        prefixIcon: Icon(
                          Icons.auto_fix_high_outlined,
                          color: AppColors.primary.withValues(alpha: 0.5),
                          size: 20,
                        ),
                      ),
                      cursorColor: AppColors.primary,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () {
                            final nav = Navigator.of(context);
                            if (nav.canPop()) nav.pop();
                          },
                          child: Container(
                            height: 52,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
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
                                  fontSize: 14.5,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: GestureDetector(
                          onTap: () {
                            // Close dialog immediately for better UX
                            final nav = Navigator.of(context);
                            if (nav.canPop()) nav.pop();
                            // Start save in background
                            _saveLookToDb(nameController.text);
                          },
                          child: Container(
                            height: 52,
                            decoration: BoxDecoration(
                              color: AppColors.primary,
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.primary.withValues(
                                    alpha: 0.38,
                                  ),
                                  blurRadius: 18,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                            ),
                            child: const Center(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.bookmark_added_rounded,
                                    color: Colors.white,
                                    size: 18,
                                  ),
                                  SizedBox(width: 7),
                                  Text(
                                    'Save look',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 15,
                                      letterSpacing: 0.1,
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
                ],
              ),
            ),
          ),
        ),
      ),
    ).then((_) => _clearSaveDialogFreeze());
  }

  // 💚 ── BUY THIS LOOK BOTTOM SHEET ────────────────────────────────────────────
  void _showWearOrderOnly(List<WearOrderLine> lines) {
    if (!mounted || lines.isEmpty) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _WearOrderSheet(lines: lines),
    );
  }

  void _showBuyThisLookSheet(
    String lookId,
    String lookName,
    List<Map<String, dynamic>> itemsToInsert,
    List<WearOrderLine> wearLines,
  ) {
    if (!mounted) return;

    // ProductsCache.totalFor reports how many of the keys it could actually
    // price. That matters: the catalog cache can be cold or a product can have
    // a null price, and quoting a total that silently omits items would be
    // worse than admitting the total is partial.
    final productKeys = itemsToInsert
        .map((item) => item['product_key'] as String?)
        .whereType<String>()
        .toList();
    final totals = ProductsCache.instance.totalFor(productKeys);

    // Delay the sheet slightly to let the snackbar settle
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted) return;

      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => _BuyThisLookSheet(
          lookId: lookId,
          lookName: lookName,
          totalPrice: totals.total,
          itemCount: productKeys.length,
          pricedCount: totals.pricedCount,
          wearLines: wearLines,
        ),
      );
    });
  }

  // ── BUILD ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    AppColors.watch(context);
    final currentSelectedShade = _selectedShades[_currentCategory];
    final currentIntensity = _intensities[_currentCategory] ?? 0.5;
    final bool isLoggedIn = Supabase.instance.client.auth.currentUser != null;
    final topPad = MediaQuery.of(context).padding.top;
    final botPad = MediaQuery.of(context).padding.bottom;
    // 🆕 Bottom sheet is capped to a fraction of the screen so, no matter how
    // many feature rows it grows (category tabs, bag toggle, find-my-shade,
    // shade strip, intensity slider), the camera preview above it always
    // keeps a guaranteed amount of visible space. Content inside scrolls
    // instead of pushing the sheet — and therefore the camera — smaller.
    // One height for lipstick, blush, foundation and every other category.
    // It used to grow with the foundation strip until it covered about half
    // the camera.
    final panelHeight = 236.0 + botPad;

    return WillPopScope(
      // 🆕 FIX v2: the overlay Navigator (_overlayNavKey) is NOT the app's
      // primary router, so Android's system back button doesn't reach it
      // automatically. While it has something pushed, forward back-presses
      // to it instead of letting them hit (or bypass) the root Navigator.
      onWillPop: () async {
        if (_compareOpen) {
          _closeCompare(useWinner: false);
          return false;
        }
        if (_comparePicking) {
          _cancelShadeComparePick();
          return false;
        }
        final overlay = _overlayNavKey.currentState;
        if (_overlayActive && overlay != null && overlay.canPop()) {
          overlay.pop();
          return false;
        }
        // Try-on is often the only route. Popping it empties the navigator
        // and trips `_history.isNotEmpty` on the next build.
        if (!Navigator.of(context).canPop()) return false;
        return true;
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
        ),
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
            // ── CAMERA ────────────────────────────────────────────────────
            // CRITICAL: DeepArPreview must ALWAYS be in the widget tree from
            // the very first frame, even before initialize() is called.
            // Conditionally removing it causes Android to destroy and recreate
            // the SurfaceView, producing EGL_BAD_NATIVE_WINDOW errors.
            // The loading overlay is stacked on top until _isInitialized.
            // ── CAMERA ────────────────────────────────────────────────────
            // 🔧 FIX: ALWAYS render DeepArPreview — never conditionally remove it
            // The black overlay on top will hide it while we're initializing.
            // This prevents SurfaceView destruction and EGL_BAD_NATIVE_WINDOW errors.
            Positioned.fill(
              top: topPad,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                child: DeepArPreview(_deepArController, key: _deepArKey,
                    alignment: Alignment.topCenter),
              ),
            ),
            if (_isSaveDialogOpen && _saveDialogFrameBytes != null)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    image: DecorationImage(
                      image: MemoryImage(_saveDialogFrameBytes!),
                      fit: BoxFit.cover,
                    ),
                  ),
                  child: const ColoredBox(color: Color.fromRGBO(0, 0, 0, 0.03)),
                ),
              ),
            // Loading / error overlay — shown until AR is ready
            if (!_isInitialized)
              Positioned.fill(
                child: _initFailed
                    ? _ErrorView(
                        message: _cameraAccessOff ? 'Camera access is off.' : null,
                        onRetry: () {
                          if (_initInProgress || _reinitCycleActive) return;
                          _reinitCycleActive = true;
                          _lastReinitAt = DateTime.now();
                          _faceGuidanceTimer?.cancel();
                          _faceGuidanceTimer = null;
                          setState(() {
                            _isInitialized = false;
                            _initFailed = false;
                            _cameraAccessOff = false;
                            _faceVisible = false;
                            _trackedFaceCount = null;
                            _faceGuidance = const FaceGuidanceState();
                            _surfaceReady = false;
                          });
                          _destroyAndResetController().then((_) {
                            if (!mounted) {
                              _reinitCycleActive = false;
                              return;
                            }
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) {
                                _waitForSurfaceThenInit();
                              } else {
                                _reinitCycleActive = false;
                              }
                            });
                          });
                        },
                      )
                    : const _LoadingView(),
              ),

            // ── TOP GRADIENT ──────────────────────────────────────────────
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: topPad + 100,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.55),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),

            // ── BOTTOM GRADIENT ───────────────────────────────────────────
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              height: 240,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.18),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),

            Positioned(
              top: topPad + 72, left: 16, right: 16,
              child: IgnorePointer(child: Center(child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: _isInitialized && _faceGuidance.bannerMessage != null
                    ? _FaceHint(key: ValueKey(_faceGuidance.banner), kind: _faceGuidance.banner)
                    : const SizedBox.shrink(),
              ))),
            ),

            // ── TOP BAR ───────────────────────────────────────────────────
            Positioned(
              top: topPad + 10,
              left: 18,
              right: 18,
              child: FadeTransition(
                opacity: _topBarFade,
                child: SlideTransition(
                  position: _topBarSlide,
                  child: Row(
                    children: [
                      _CameraPill(child: TextButton.icon(
                        onPressed: _openHome,
                        icon: const Icon(Icons.home_outlined, size: 20),
                        label: const Text('Home'),
                        style: TextButton.styleFrom(foregroundColor: const Color(0xfffff6eb),
                          minimumSize: const Size(48, 48)),
                      )),
                      const Spacer(),
                      _CameraPill(child: Row(mainAxisSize: MainAxisSize.min,children: [
                      IconButton(
                        tooltip: 'Saved looks',
                        onPressed: isLoggedIn
                            ? () async {
                                final items = await _pushOverlay<dynamic>(
                                  const SavedLooksScreen(),
                                );
                                if (items != null && items is List) {
                                  _loadAndApplySavedLook(items);
                                }
                              }
                            : () => _showLoginPrompt(
                                'Sign in to view your saved looks!',
                              ),
                        icon: const Icon(Icons.photo_library_outlined),
                      ),
                      Container(width: 1, height: 18, color: Colors.white38),
                      IconButton(
                        tooltip: isLoggedIn ? 'Profile' : 'Sign in',
                        onPressed: () async {
                          if (isLoggedIn) {
                            final result = await _pushOverlay<Object>(
                              const ProfileScreen(),
                            );
                            await _handleOverlayResult(result);
                          } else {
                            await _pushOverlay<void>(
                              const AuthScreen(isLoginMode: true),
                            );
                          }
                        },
                        icon: Icon(
                          isLoggedIn
                              ? Icons.person_outline_rounded
                              : Icons.login_rounded,
                          size: 22,
                        ),
                      ),
                      ])),
                    ],
                  ),
                ),
              ),
            ),

            if (_isInitialized && !_compareOpen)
              Positioned(
                left: 12,
                right: 12,
                bottom: panelHeight + 8,
                child: _buildDemoControls(),
              ),

            // ── BOTTOM PANEL ──────────────────────────────────────────────
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: FadeTransition(
                opacity: _panelFade,
                child: SlideTransition(
                  position: _panelSlide,
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(36),
                    ),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                      child: SizedBox(
                        height: panelHeight,
                        child: Container(
                          decoration: BoxDecoration(
                            color: AppColors.surface.withValues(alpha: 0.95),
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(36),
                            ),
                            border: Border(
                              top: BorderSide(
                                color: AppColors.border,
                                width: 1.2,
                              ),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.12),
                                blurRadius: 30,
                                offset: const Offset(0, -8),
                              ),
                            ],
                          ),
                          child: Column(
                            children: [
                              // Drag handle — stays fixed at the top of the
                              // panel regardless of how much content scrolls
                              // beneath it.
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: 10,
                                  bottom: 2,
                                ),
                                child: Container(
                                  width: 36,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: AppColors.textMuted.withValues(
                                      alpha: 0.25,
                                    ),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),

                              // 🆕 Everything else scrolls within the capped
                              // height instead of forcing the panel taller.
                              Flexible(
                                child: SingleChildScrollView(
                                  physics: const BouncingScrollPhysics(),
                                  padding: EdgeInsets.fromLTRB(
                                    16,
                                    4,
                                    16,
                                    botPad + 8,
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      // ── Category chips and compact controls ─
                                      Row(
                                        children: [
                                          Expanded(
                                            child: SingleChildScrollView(
                                              scrollDirection: Axis.horizontal,
                                              physics:
                                                  const BouncingScrollPhysics(),
                                              child: Row(
                                                children: TryOnCategory.values
                                                    .where(
                                                      (cat) =>
                                                          cat !=
                                                              TryOnCategory
                                                                  .highlighter &&
                                                          (cat !=
                                                                  TryOnCategory
                                                                      .mascara ||
                                                              _showMascaraChip),
                                                    )
                                                    .map(_buildCategoryTab)
                                                    .toList(),
                                              ),
                                            ),
                                          ),
                                          _panelIcon(
                                            icon: _showOnlyMyBag
                                                ? Icons.shopping_bag
                                                : Icons.shopping_bag_outlined,
                                            label: 'My bag',
                                            selected: _showOnlyMyBag,
                                            onTap: () {
                                              if (!isLoggedIn) {
                                                _showLoginPrompt(
                                                  'Sign in to view your bag!',
                                                );
                                                return;
                                              }
                                              setState(
                                                () => _showOnlyMyBag =
                                                    !_showOnlyMyBag,
                                              );
                                            },
                                          ),
                                          if (_currentCategory ==
                                              TryOnCategory.foundation)
                                            Semantics(
                                              button: true,
                                              label: 'Find my shade',
                                              child: GestureDetector(
                                                onTap: _openFoundationMatcher,
                                                behavior: HitTestBehavior.opaque,
                                                child: Container(
                                                  height: 48,
                                                  margin: const EdgeInsets.only(
                                                    left: 6,
                                                  ),
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                    horizontal: 10,
                                                  ),
                                                  alignment: Alignment.center,
                                                  decoration: BoxDecoration(
                                                    color: AppColors.primary,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                      50,
                                                    ),
                                                  ),
                                                  child: const Text(
                                                    'Find my shade',
                                                    style: TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 12,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),

                                      // ── Shade label row ──────────────────
                                      Row(
                                        children: [
                                          Container(
                                            width: 3,
                                            height: 14,
                                            margin: const EdgeInsets.only(
                                                right: 8),
                                            decoration: BoxDecoration(
                                              color: currentSelectedShade !=
                                                      null
                                                  ? AppColors.primary
                                                  : AppColors.border,
                                              borderRadius:
                                                  BorderRadius.circular(
                                                2,
                                              ),
                                            ),
                                          ),
                                          Expanded(
                                            child: Text(
                                              currentSelectedShade != null
                                                  ? currentSelectedShade
                                                      .shadeName
                                                  : 'Choose a shade below',
                                              style: TextStyle(
                                                fontSize: 12.5,
                                                color: currentSelectedShade !=
                                                        null
                                                    ? AppColors.textMain
                                                    : AppColors.textMuted,
                                                fontWeight:
                                                    currentSelectedShade !=
                                                            null
                                                        ? FontWeight.w600
                                                        : FontWeight.w400,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          if (currentSelectedShade != null)
                                            _MiniColorDot(
                                              color:
                                                  currentSelectedShade.color,
                                            ),
                                          if (currentSelectedShade !=
                                              null) ...[
                                            const SizedBox(width: 8),
                                            ListenableBuilder(
                                              listenable:
                                                  FavouritesCache.instance,
                                              builder: (context, _) {
                                                final isFav = FavouritesCache
                                                    .instance
                                                    .isFavourite(
                                                  currentSelectedShade
                                                      .productKey,
                                                  currentSelectedShade
                                                      .shadeKey,
                                                );
                                                return GestureDetector(
                                                  onTap: () {
                                                    final user = Supabase
                                                        .instance
                                                        .client
                                                        .auth
                                                        .currentUser;
                                                    if (user == null) {
                                                      _showLoginPrompt(
                                                        'Sign in to save favourites!',
                                                      );
                                                      return;
                                                    }
                                                    FavouritesCache.instance
                                                        .toggleFavourite(
                                                      currentSelectedShade
                                                          .productKey,
                                                      currentSelectedShade
                                                          .shadeKey,
                                                    );
                                                  },
                                                  child: AnimatedContainer(
                                                    duration: const Duration(
                                                      milliseconds: 200,
                                                    ),
                                                    padding:
                                                        const EdgeInsets.all(
                                                      6,
                                                    ),
                                                    decoration: BoxDecoration(
                                                      color: isFav
                                                          ? AppColors.primary
                                                              .withOpacity(
                                                                  0.1)
                                                          : Colors
                                                              .transparent,
                                                      shape: BoxShape.circle,
                                                    ),
                                                    child: Icon(
                                                      isFav
                                                          ? Icons
                                                              .favorite_rounded
                                                          : Icons
                                                              .favorite_border_rounded,
                                                      color: isFav
                                                          ? AppColors.primary
                                                          : AppColors
                                                              .textMuted,
                                                      size: 20,
                                                    ),
                                                  ),
                                                );
                                              },
                                            ),
                                            const SizedBox(width: 4),
                                            ListenableBuilder(
                                              listenable:
                                                  MakeupBagCache.instance,
                                              builder: (context, _) {
                                                final inBag = MakeupBagCache
                                                    .instance
                                                    .isInBag(
                                                  currentSelectedShade
                                                      .productKey,
                                                  currentSelectedShade
                                                      .shadeKey,
                                                );
                                                return GestureDetector(
                                                  onTap: () {
                                                    final user = Supabase
                                                        .instance
                                                        .client
                                                        .auth
                                                        .currentUser;
                                                    if (user == null) {
                                                      _showLoginPrompt(
                                                        'Sign in to add to your bag!',
                                                      );
                                                      return;
                                                    }
                                                    MakeupBagCache.instance
                                                        .toggleInBag(
                                                      currentSelectedShade
                                                          .productKey,
                                                      currentSelectedShade
                                                          .shadeKey,
                                                    );
                                                  },
                                                  child: AnimatedContainer(
                                                    duration: const Duration(
                                                      milliseconds: 200,
                                                    ),
                                                    padding:
                                                        const EdgeInsets.all(
                                                      6,
                                                    ),
                                                    decoration: BoxDecoration(
                                                      color: inBag
                                                          ? AppColors.primary
                                                              .withOpacity(
                                                                  0.1)
                                                          : Colors
                                                              .transparent,
                                                      shape: BoxShape.circle,
                                                    ),
                                                    child: Icon(
                                                      inBag
                                                          ? Icons
                                                              .shopping_bag_rounded
                                                          : Icons
                                                              .shopping_bag_outlined,
                                                      color: inBag
                                                          ? AppColors.primary
                                                          : AppColors
                                                              .textMuted,
                                                      size: 20,
                                                    ),
                                                  ),
                                                );
                                              },
                                            ),
                                          ],
                                        ],
                                      ),

                                      if (_demoStatus != null) ...[
                                        const SizedBox(height: 6),
                                        Text(
                                          _demoStatus!,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: AppColors.primary,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],

                                      const SizedBox(height: 8),

                                      // ── Shades list ──────────────────────
                                      SizedBox(
                                        height: 52,
                                        child: _currentShades.isEmpty
                                            ? Center(
                                                child: GestureDetector(
                                                  onTap: _shadeLoadError == null
                                                      ? null
                                                      : () {
                                                          setState(() {
                                                            _shadeLoadSettled =
                                                                false;
                                                            _shadeLoadError =
                                                                null;
                                                          });
                                                          _loadDataFromDb();
                                                        },
                                                  child: Text(
                                                    _shadeLoadError ??
                                                        (_shadeLoadSettled
                                                            ? 'No shades available'
                                                            : 'Loading shades…'),
                                                    textAlign: TextAlign.center,
                                                    style: TextStyle(
                                                      color:
                                                          AppColors.textMuted,
                                                      fontSize: 13,
                                                    ),
                                                  ),
                                                ),
                                              )
                                            : ListView.builder(
                                                scrollDirection:
                                                    Axis.horizontal,
                                                physics:
                                                    const BouncingScrollPhysics(),
                                                itemCount:
                                                    _currentShades.length +
                                                        1,
                                                itemBuilder:
                                                    (context, index) {
                                                  if (index == 0) {
                                                    final cleared =
                                                        currentSelectedShade ==
                                                            null;
                                                    return GestureDetector(
                                                      onTap: () {
                                                        setState(
                                                          () => _selectedShades[
                                                                  _currentCategory] =
                                                              null,
                                                        );
                                                        _applyColorToDeepAR(
                                                          null,
                                                          _currentCategory,
                                                        );
                                                      },
                                                      child: _ShadeCircle(
                                                        isSelected: cleared,
                                                        child: Icon(
                                                          Icons.block_rounded,
                                                          color: AppColors
                                                              .textMuted,
                                                          size: 18,
                                                        ),
                                                      ),
                                                    );
                                                  }

                                                  final shade =
                                                      _currentShades[
                                                          index - 1];
                                                  final isSelected =
                                                      currentSelectedShade !=
                                                              null &&
                                                          shade.productKey ==
                                                              currentSelectedShade
                                                                  .productKey;

                                                  Color displayColor =
                                                      shade.color;
                                                  if ((_currentCategory ==
                                                              TryOnCategory
                                                                  .eyelashes ||
                                                          _currentCategory ==
                                                              TryOnCategory
                                                                  .mascara) &&
                                                      _lashConfigs.containsKey(
                                                        shade.productKey,
                                                      )) {
                                                    displayColor =
                                                        _lashConfigs[shade
                                                                .productKey]!
                                                            .color;
                                                  }

                                                  return GestureDetector(
                                                    onTap: () {
                                                      if (_isHighlighter(
                                                        category:
                                                            _currentCategory,
                                                        productKey:
                                                            shade.productKey,
                                                      )) {
                                                        _showSnack(
                                                          "Highlighter isn't in this effect.",
                                                        );
                                                        return;
                                                      }
                                                      if (_comparePicking &&
                                                          _currentCategory ==
                                                              _comparePickCategory) {
                                                        _onCompareShadeTapped(
                                                          shade,
                                                        );
                                                        return;
                                                      }
                                                      setState(
                                                        () => _selectedShades[
                                                                _currentCategory] =
                                                            shade,
                                                      );
                                                      _applyColorToDeepAR(
                                                        shade,
                                                        _currentCategory,
                                                      );
                                                    },
                                                    child: Stack(
                                                      children: [
                                                        _ShadeCircle(
                                                          color:
                                                              displayColor,
                                                          isSelected:
                                                              isSelected,
                                                        ),
                                                        // Closest-match badge on the
                                                        // first foundation swatch.
                                                        // When a match was saved, that
                                                        // shade is pinned first. With
                                                        // no saved recommendation the
                                                        // list is still sorted by ΔE.
                                                        if (_currentPrefix ==
                                                                'fnd_' &&
                                                            index == 1 &&
                                                            _foundationSkinHex !=
                                                                null)
                                                          Positioned(
                                                            top: -4,
                                                            right: -4,
                                                            child: Tooltip(
                                                              message: _closestFoundationDeltaE ==
                                                                      null
                                                                  ? 'Closest match to your skin tone'
                                                                  : 'Closest match — ΔE '
                                                                      '${_closestFoundationDeltaE!.toStringAsFixed(1)} · '
                                                                      '${describeDeltaE(_closestFoundationDeltaE!)}',
                                                              child:
                                                                  Container(
                                                                width: 20,
                                                                height: 20,
                                                                decoration:
                                                                    BoxDecoration(
                                                                  // Coloured by how
                                                                  // good the match
                                                                  // actually is. A
                                                                  // permanently green
                                                                  // badge over a ΔE 9
                                                                  // shade would be a
                                                                  // lie the user can
                                                                  // see in the mirror.
                                                                  color: _deltaEBadgeColour(
                                                                    _closestFoundationDeltaE,
                                                                  ),
                                                                  shape:
                                                                      BoxShape
                                                                          .circle,
                                                                  border: Border
                                                                      .all(
                                                                    color: Colors
                                                                        .white,
                                                                    width:
                                                                        1.5,
                                                                  ),
                                                                ),
                                                                child:
                                                                    const Center(
                                                                  child: Icon(
                                                                    Icons
                                                                        .check_rounded,
                                                                    size: 12,
                                                                    color: Colors
                                                                        .white,
                                                                  ),
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                      ],
                                                    ),
                                                  );
                                                },
                                              ),
                                      ),

                                      const SizedBox(height: 10),

                                      // ── Intensity slider ─────────────────
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: AppColors.primary
                                              .withValues(
                                            alpha: 0.05,
                                          ),
                                          borderRadius:
                                              BorderRadius.circular(16),
                                          border: Border.all(
                                            color: AppColors.primary
                                                .withValues(
                                              alpha: 0.10,
                                            ),
                                            width: 1,
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(
                                              Icons.water_drop_outlined,
                                              color: AppColors.primary
                                                  .withValues(
                                                alpha: 0.7,
                                              ),
                                              size: 16,
                                            ),
                                            const SizedBox(width: 7),
                                            Text(
                                              'Intensity',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: AppColors.textMuted,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            Expanded(
                                              child: SliderTheme(
                                                data: SliderTheme.of(context)
                                                    .copyWith(
                                                  activeTrackColor:
                                                      AppColors.primary,
                                                  inactiveTrackColor:
                                                      AppColors.primary
                                                          .withValues(
                                                              alpha: 0.12),
                                                  thumbColor: Colors.white,
                                                  overlayColor: AppColors
                                                      .primary
                                                      .withValues(
                                                          alpha: 0.12),
                                                  thumbShape:
                                                      const RoundSliderThumbShape(
                                                    enabledThumbRadius: 8,
                                                  ),
                                                  trackHeight: 2.5,
                                                  overlayShape:
                                                      const RoundSliderOverlayShape(
                                                    overlayRadius: 18,
                                                  ),
                                                ),
                                                child: Slider(
                                                  value: currentIntensity,
                                                  min: 0.0,
                                                  max: 1.0,
                                                  onChanged:
                                                      currentSelectedShade ==
                                                              null
                                                          ? null
                                                          : (val) {
                                                              setState(
                                                                () => _intensities[
                                                                        _currentCategory] =
                                                                    val,
                                                              );
                                                              _applyColorToDeepAR(
                                                                currentSelectedShade,
                                                                _currentCategory,
                                                              );
                                                            },
                                                ),
                                              ),
                                            ),
                                            Container(
                                              width: 42,
                                              alignment: Alignment.center,
                                              child: Text(
                                                '${(currentIntensity * 100).round()}%',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: AppColors.primary,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (_compareOpen &&
                _compareLeftBytes != null &&
                _compareRightBytes != null)
              Positioned.fill(
                child: _StillCompareOverlay(
                  left: _compareLeftBytes!,
                  right: _compareRightBytes!,
                  leftLabel: _compareLeftLabel,
                  rightLabel: _compareRightLabel,
                  split: _compareSplit,
                  showUse: _compareChoosesShade,
                  onSplit: (value) => setState(() => _compareSplit = value),
                  onClose: () => _closeCompare(useWinner: false),
                  onUse: () => _closeCompare(useWinner: true),
                ),
              ),
            // ── OVERLAY NAVIGATOR ────────────────────────────────────────
            // 🆕 FIX v2: AuthScreen / ProfileScreen / SavedLooksScreen are
            // pushed onto THIS Navigator (via _pushOverlay), never the root
            // one. It lives entirely inside TryOnScreen's own widget tree,
            // so pushing/popping routes on it never touches the root
            // Navigator's Overlay — which is what DeepAR's SurfaceView is
            // composited relative to via hybrid composition, and what was
            // triggering the "disconnected/abandoned window" /
            // EGL_BAD_NATIVE_WINDOW loop on sign-in. IgnorePointer keeps it
            // from intercepting camera-area touches when nothing is pushed.
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !_overlayActive,
                child: Navigator(
                  key: _overlayNavKey,
                  // A permanent root page. Popping the last route of this
                  // nested navigator used to empty `_history` and fail the
                  // framework assertion on the next build, which left the
                  // camera spinner up under a red error screen.
                  pages: const [
                    MaterialPage<void>(
                      key: ValueKey<String>('try-on-overlay-root'),
                      child: SizedBox.shrink(),
                    ),
                  ],
                  onPopPage: (route, result) => false,
                ),
              ),
            ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDemoControls() {
    final isLoggedIn = Supabase.instance.client.auth.currentUser != null;
    const captions = [
      'Tap Save to keep this look.',
      'Press and hold to hide the makeup.',
      'Tap Compare to see two shades.',
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_coachStep != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        captions[_coachStep!],
                        style: const TextStyle(
                          color: Color(0xFF1F1F1F),
                          fontSize: 14,
                          height: 1.35,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _advanceCoach,
                      child: Text(
                        _coachStep == 2 ? 'Done' : 'Next',
                        style: TextStyle(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Listener(
                onPointerDown: (_) => _beginBareHold(),
                onPointerUp: (_) => _endBareHold(),
                onPointerCancel: (_) => _endBareHold(),
                child: _ShutterSide(
                  icon: _bareHoldActive
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  label: 'Hold',
                  active: _bareHoldActive || _coachStep == 1,
                ),
              ),
            ),
            _ShutterSave(
              highlighted: _coachStep == 0,
              onTap: isLoggedIn
                  ? () => _showSaveLookDialog()
                  : () => _showLoginPrompt('Sign in to save your look!'),
            ),
            Expanded(
              child: _ShutterSide(
                icon: Icons.vertical_split_rounded,
                label: 'Compare',
                active: _coachStep == 2,
                onTap: _shadeCaptureBusy
                    ? null
                    : () => _startShadeCompare(_currentCategory),
              ),
            ),
          ],
        ),
        if (_comparePicking)
          TextButton(
            onPressed: _cancelShadeComparePick,
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
      ],
    );
  }

  // ── CATEGORY TAB ──────────────────────────────────────────────────────────

  Widget _panelIcon({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool selected = false,
  }) {
    return Semantics(
      button: true,
      label: label,
      selected: selected,
      child: GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        margin: const EdgeInsets.only(left: 6),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : AppColors.background,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
          ),
        ),
        child: Icon(
          icon,
          size: 16,
          color: selected ? Colors.white : AppColors.textMain,
        ),
      ),
    ),
    );
  }

  Widget _buildCategoryTab(TryOnCategory cat) {
    final isSelected = _currentCategory == cat;
    final hasShade = _selectedShades[cat] != null;

    return Semantics(
      button: true,
      selected: isSelected,
      label: _getCategoryName(cat),
      child: GestureDetector(
      onTap: () {
        if (_comparePicking && cat != _comparePickCategory) {
          _cancelShadeComparePick();
        }
        setState(() => _currentCategory = cat);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        margin: const EdgeInsets.only(right: 7),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(50),
          border: Border.all(
            color: isSelected
                ? AppColors.primary
                : hasShade
                ? AppColors.primary.withValues(alpha: 0.35)
                : AppColors.border,
            width: isSelected ? 0 : 1.2,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.30),
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
              _getCategoryIcon(cat),
              size: 12,
              color: isSelected
                  ? Colors.white
                  : hasShade
                  ? AppColors.primary
                  : AppColors.textMuted,
            ),
            const SizedBox(width: 5),
            Text(
              _getCategoryName(cat),
              style: TextStyle(
                color: isSelected
                    ? Colors.white
                    : hasShade
                    ? AppColors.primary
                    : AppColors.textMuted,
                fontWeight: isSelected || hasShade
                    ? FontWeight.w700
                    : FontWeight.w500,
                fontSize: 12.5,
              ),
            ),
            if (hasShade && !isSelected) ...[
              const SizedBox(width: 5),
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: _selectedShades[cat]!.color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.4),
                    width: 0.8,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      ),
    );
  }
}

// ── HELPER WIDGETS ────────────────────────────────────────────────────────────

class _LoadingView extends StatefulWidget {
  const _LoadingView();

  @override
  State<_LoadingView> createState() => _LoadingViewState();
}

class _LoadingViewState extends State<_LoadingView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _turn.reset();
    } else if (!_turn.isAnimating) {
      _turn.repeat();
    }
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.background,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 64,
              child: Center(
                child: AnimatedBuilder(
                  animation: _turn,
                  builder: (context, logo) => Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..setEntry(3, 2, 0.0015)
                      ..rotateY(_turn.value * 2 * math.pi),
                    child: logo,
                  ),
                  child: Image.asset(
                    'assets/images/oval_face_ivory.png',
                    width: 34,
                    height: 50,
                    fit: BoxFit.contain,
                    color: AppColors.isDark ? null : const Color(0xff51243f),
                    excludeFromSemantics: true,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Preparing AR experience…',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'This takes just a moment',
              style: TextStyle(
                color: AppColors.textMuted.withValues(alpha: 0.55),
                fontSize: 11.5,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final VoidCallback onRetry;
  final String? message;
  const _ErrorView({required this.onRetry, this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.background,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: Colors.redAccent.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.redAccent.withValues(alpha: 0.20),
                    width: 1.5,
                  ),
                ),
                child: const Center(
                  child: Icon(
                    Icons.camera_alt_outlined,
                    color: Colors.redAccent,
                    size: 28,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                message ?? 'Camera unavailable',
                style: TextStyle(
                  color: AppColors.textMain,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message == null
                    ? 'Could not start the AR camera.\nPlease try again.'
                    : 'Allow camera access, then try again.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 13.5,
                  height: 1.55,
                ),
              ),
              const SizedBox(height: 24),
              GestureDetector(
                onTap: onRetry,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 13,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(50),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.primary.withValues(alpha: 0.35),
                        blurRadius: 14,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: const Text(
                    'Try Again',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 14.5,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShutterSave extends StatelessWidget {
  final bool highlighted;
  final VoidCallback onTap;
  const _ShutterSave({required this.highlighted, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Save',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: GestureDetector(
          onTap: onTap,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                  border: Border.all(
                    color: highlighted ? AppColors.primary : Colors.white,
                    width: highlighted ? 3 : 0,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.26),
                      blurRadius: 14,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: Center(
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFF1F1F1F),
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Save',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShutterSide extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onTap;
  const _ShutterSide({
    required this.icon,
    required this.label,
    required this.active,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withValues(alpha: active ? 0.55 : 0.32),
                  border: Border.all(
                    color: active
                        ? AppColors.primary
                        : Colors.white.withValues(alpha: 0.7),
                    width: active ? 2 : 1.2,
                  ),
                ),
                child: Icon(icon, color: Colors.white, size: 23),
              ),
              const SizedBox(height: 5),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SplitClipper extends CustomClipper<Rect> {
  _SplitClipper(this.fraction);
  final double fraction;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width * fraction, size.height);

  @override
  bool shouldReclip(_SplitClipper oldClipper) => oldClipper.fraction != fraction;
}

class _StillCompareOverlay extends StatelessWidget {
  const _StillCompareOverlay({
    required this.left,
    required this.right,
    required this.leftLabel,
    required this.rightLabel,
    required this.split,
    required this.showUse,
    required this.onSplit,
    required this.onClose,
    required this.onUse,
  });

  final Uint8List left;
  final Uint8List right;
  final String leftLabel;
  final String rightLabel;
  final double split;
  final bool showUse;
  final ValueChanged<double> onSplit;
  final VoidCallback onClose;
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context) {
    final winner = split >= 0.5 ? leftLabel : rightLabel;
    return ColoredBox(
      color: Colors.black,
      child: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                onPressed: onClose,
                icon: const Icon(Icons.close_rounded, color: Colors.white),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.memory(
                            right,
                            fit: BoxFit.cover,
                            width: constraints.maxWidth,
                            height: constraints.maxHeight,
                          ),
                          ClipRect(
                            clipper: _SplitClipper(split),
                            child: Image.memory(
                              left,
                              fit: BoxFit.cover,
                              width: constraints.maxWidth,
                              height: constraints.maxHeight,
                            ),
                          ),
                          Positioned(
                            left: constraints.maxWidth * split - 1,
                            top: 0,
                            bottom: 0,
                            child: Container(width: 2, color: Colors.white),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      leftLabel,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      rightLabel,
                      textAlign: TextAlign.right,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            Slider(
              value: split.clamp(0.02, 0.98),
              min: 0.02,
              max: 0.98,
              activeColor: AppColors.primary,
              onChanged: onSplit,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: showUse
                  ? SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        onPressed: onUse,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: Text(
                          'Use this one · $winner',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    )
                  : TextButton(
                      onPressed: onClose,
                      child: const Text(
                        'Close',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CameraPill extends StatelessWidget {
  const _CameraPill({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xd0393536),
    shape: const StadiumBorder(),
    clipBehavior: Clip.antiAlias,
    child: IconButtonTheme(
      data: IconButtonThemeData(style: IconButton.styleFrom(
        foregroundColor: const Color(0xfffff6eb), minimumSize: const Size(48,48))),
      child: child),
  );
}

class _FaceHint extends StatefulWidget {
  const _FaceHint({super.key, required this.kind});
  final FaceGuidanceKind kind;
  @override
  State<_FaceHint> createState() => _FaceHintState();
}

class _FaceHintState extends State<_FaceHint> {
  Timer? timer;
  bool showLightingTip = false;
  @override
  void initState() {
    super.initState();
    if (widget.kind == FaceGuidanceKind.noFace) {
      timer = Timer(const Duration(seconds: 5), () => setState(() => showLightingTip = true));
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.kind == FaceGuidanceKind.severalFaces
        ? FaceGuidance.severalFacesMessage
        : showLightingTip ? 'Face the camera in good light' : 'Bring your face into view';
    return Semantics(liveRegion: true, child: DecoratedBox(
      decoration: const ShapeDecoration(color: Color(0xd0393536),shape: StadiumBorder()),
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14,vertical: 8),
        child: Row(mainAxisSize: MainAxisSize.min,children: [
          const Icon(Icons.info_outline_rounded,color: Color(0xfffff6eb),size: 18),
          const SizedBox(width: 8),
          Flexible(child: Text(message,style: const TextStyle(color: Color(0xfffff6eb),fontSize: 14))),
        ])),
    ));
  }
}

class _ShadeCircle extends StatelessWidget {
  final Color? color;
  final bool isSelected;
  final Widget? child;
  const _ShadeCircle({this.color, required this.isSelected, this.child});

  @override
  Widget build(BuildContext context) {
    // Inner dot color: white on dark shades, dark primary on light shades
    final bool isDarkShade = color != null
        ? (color!.computeLuminance() < 0.35)
        : false;
    final Color innerDotColor = isDarkShade
        ? Colors.white.withValues(alpha: 0.88)
        : AppColors.primary;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      margin: const EdgeInsets.only(right: 10),
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: color ?? AppColors.surface,
        shape: BoxShape.circle,
        border: Border.all(
          color: isSelected ? AppColors.primary : AppColors.surface,
          width: isSelected ? 3 : 2,
        ),
        boxShadow: [
          BoxShadow(
            color: isSelected
                ? AppColors.primary.withValues(alpha: 0.45)
                : Colors.black.withValues(alpha: 0.12),
            blurRadius: isSelected ? 14 : 5,
            spreadRadius: isSelected ? 1 : 0,
          ),
        ],
      ),
      child: child != null
          ? Center(child: child)
          : isSelected
          ? Center(
              child: Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  color: innerDotColor,
                  shape: BoxShape.circle,
                ),
              ),
            )
          : null,
    );
  }
}

class _MiniColorDot extends StatelessWidget {
  final Color color;
  const _MiniColorDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2.5),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.45),
            blurRadius: 7,
            spreadRadius: 1,
          ),
        ],
      ),
    );
  }
}

/// Offered right after a look is saved: take this look to the web store and buy
/// everything in it.
///
/// The purchase itself deliberately does not happen in the app. The cart, Stripe
/// checkout and order history all live on the website, so duplicating them here
/// would mean two carts that can disagree. Instead this hands the user's session
/// to their browser via [WebBridge.openAuthenticated] and lands on
/// `/looks/<id>?action=buy`, where the web app fills its own cart from the look
/// and goes straight to checkout.
class _WearOrderSheet extends StatelessWidget {
  const _WearOrderSheet({required this.lines});

  final List<WearOrderLine> lines;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 10, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.neutral300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _WearOrderBlock(lines: lines),
            ],
          ),
        ),
      ),
    );
  }
}

class _WearOrderBlock extends StatelessWidget {
  const _WearOrderBlock({required this.lines});

  final List<WearOrderLine> lines;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Wear order',
          style: TextStyle(
            color: AppColors.textMain,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 92,
                  child: Text(
                    line.zoneLabel,
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    line.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: line.missing ? AppColors.textMuted : AppColors.textMain,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      fontStyle: line.missing ? FontStyle.italic : FontStyle.normal,
                    ),
                  ),
                ),
                Text(
                  '${line.intensity}%',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _BuyThisLookSheet extends StatefulWidget {
  final String lookId;
  final String lookName;
  final double totalPrice;

  /// Products in the saved look.
  final int itemCount;

  /// How many of those [ProductsCache] could price. Less than [itemCount] when
  /// the catalog cache is cold or a product has no price, in which case the
  /// total shown is a floor rather than the real figure.
  final int pricedCount;
  final List<WearOrderLine> wearLines;

  const _BuyThisLookSheet({
    required this.lookId,
    required this.lookName,
    required this.totalPrice,
    required this.itemCount,
    required this.pricedCount,
    required this.wearLines,
  });

  @override
  State<_BuyThisLookSheet> createState() => _BuyThisLookSheetState();
}

class _BuyThisLookSheetState extends State<_BuyThisLookSheet> {
  bool _opening = false;

  Future<void> _openCheckout() async {
    // Handing off involves a token refresh and a browser launch; without this
    // guard an impatient double-tap opens two tabs.
    if (_opening) return;
    setState(() => _opening = true);

    final opened = await WebBridge.openAuthenticated(
      context,
      AppConfig.buyLookPath(widget.lookId),
    );

    if (!mounted) return;
    // Only dismiss on success. WebBridge surfaces its own error, and closing the
    // sheet underneath it would leave the user with a message and no way to retry.
    if (opened) {
      final nav = Navigator.of(context);
      if (nav.canPop()) nav.pop();
    } else {
      setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool allPriced =
        widget.pricedCount == widget.itemCount && widget.itemCount > 0;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 10, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag handle
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.neutral300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),

              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.shopping_bag_rounded,
                  color: AppColors.primary,
                  size: 26,
                ),
              ),
              const SizedBox(height: 14),

              Text(
                'Love this look?',
                style: TextStyle(
                  color: AppColors.textMain,
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                widget.lookName.trim().isEmpty
                    ? 'Buy everything you just tried on.'
                    : 'Buy everything in “${widget.lookName.trim()}”.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 18),
              if (widget.wearLines.isNotEmpty) ...[
                _WearOrderBlock(lines: widget.wearLines),
                const SizedBox(height: 14),
              ],

              // ── Price summary ────────────────────────────────────────────
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: AppColors.neutral200,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${widget.itemCount} '
                            '${widget.itemCount == 1 ? 'product' : 'products'}',
                            style: TextStyle(
                              color: AppColors.textMain,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (!allPriced) ...[
                            const SizedBox(height: 3),
                            Text(
                              widget.pricedCount == 0
                                  ? 'Prices load on the web store'
                                  : 'From ${widget.pricedCount} of '
                                      '${widget.itemCount} priced',
                              style: TextStyle(
                                color: AppColors.neutral500,
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (widget.pricedCount > 0)
                      Text(
                        // A leading "~" when some items could not be priced, so
                        // the number is never read as the final basket total.
                        '${allPriced ? '' : '~'}'
                        '\$${widget.totalPrice.toStringAsFixed(2)}',
                        style: TextStyle(
                          color: AppColors.textMain,
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // ── Primary action ───────────────────────────────────────────
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: _opening ? null : _openCheckout,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    disabledBackgroundColor:
                        AppColors.primary.withValues(alpha: 0.6),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: _opening
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: AppLoader.inline(
                            size: 20,
                            strokeWidth: 2.2,
                            color: Colors.white,
                          ),
                        )
                      : const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.open_in_new_rounded, size: 18),
                            SizedBox(width: 8),
                            Text(
                              'Buy this look',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 6),

              TextButton(
                onPressed: _opening
                    ? null
                    : () {
                        final nav = Navigator.of(context);
                        if (nav.canPop()) nav.pop();
                      },
                child: Text(
                  'Not now',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
