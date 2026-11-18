import 'package:permission_handler/permission_handler.dart';
import 'camera_permission_screen.dart';
// lib/app/screens/foundation_match_screen.dart
//
// Foundation Shade Match — the screen the user actually sees.
//
// Flow: guidance → photo → on-device sampling → server ranking → result.
//
// Four things this screen is built around, each of which is a decision rather
// than a default:
//
//  1. **The guidance is part of the algorithm.** Foundation matched over existing
//     foundation measures the old foundation, and a warm bulb shifts skin further
//     than the gap between two neighbouring shades. Those two mistakes account for
//     most of the wrong answers a matcher of this kind gives, and neither is
//     fixable after the shutter. So the advice is shown before the camera opens,
//     not buried in a help page.
//
//  2. **A refusal is a result.** "Retake, the light was too warm" is a real
//     outcome and gets a designed state, not an error toast. A matcher that
//     guesses when it cannot see is worse than one that says so.
//
//  3. **Every number is explained.** ΔE, confidence and undertone all appear with
//     the reason next to them. This is also what makes the feature defensible in
//     a viva: nothing on screen is a figure the user has to take on faith.
//
//  4. **Nothing here can crash.** Every colour is parsed defensively, every
//     await is followed by a `mounted` check, and the whole result model tolerates
//     missing fields — see `foundation_match_service.dart`.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../cache/makeup_bag_cache.dart';
import '../cache/shade_disk_cache.dart';
import '../config/app_config.dart';
import '../services/beauty_profile_service.dart';
import '../services/foundation_match_service.dart';
import '../services/skin_sampler.dart';
import '../services/web_bridge.dart';
import '../utils/app_colors.dart';
import '../widgets/app_loader.dart';
import '../utils/demo_looks.dart';
import 'auth_screen.dart';
import 'foundation_capture_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Result contract
// ─────────────────────────────────────────────────────────────────────────────

/// What the screen pops when the user taps **Try in AR**.
///
/// The screen does not apply the shade itself: it may be running on top of a live
/// DeepAR surface, and the only safe way to hand a selection back is to pop with
/// it and let the try-on screen apply it once this route is gone.
class FoundationTryOnRequest {
  const FoundationTryOnRequest({
    required this.productKey,
    required this.shadeKey,
    required this.shadeName,
  });

  final String productKey;
  final String shadeKey;
  final String shadeName;
}

/// Pops when the user wants the matched foundation worn with a blush and a lip.
///
/// The try-on screen applies it through the saved-look path. This screen does
/// not touch the camera.
class FoundationLookRequest {
  const FoundationLookRequest({
    required this.productKey,
    required this.shadeKey,
    required this.shadeName,
    required this.skinHex,
    required this.undertone,
  });

  final String productKey;
  final String shadeKey;
  final String shadeName;
  final String skinHex;
  final String undertone;
}

// ─────────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────────

enum _Stage { signIn, intake, working, retake, result }

/// A red–yellow skin hue (about 40° and up, with yellow still in the reading)
/// is warm or neutral. The server used to call that cool whenever it sat a few
/// degrees redder than the depth reference.
String shownUndertone(SkinReading skin) {
  if (skin.undertone != 'cool') return skin.undertone;
  if (skin.a <= 0 || skin.b <= 0) return skin.undertone;
  final hue = math.atan2(skin.b, skin.a) * 180 / math.pi;
  if (hue >= 40) return 'neutral';
  return skin.undertone;
}

String _persistenceLine(String note) {
  if (note.contains('could not be saved to your profile') ||
      note.contains('Not saved to your profile')) {
    if (note.contains('table') || note.contains('signed in') || note.contains('rejected')) {
      return note;
    }
    return 'Not saved to your profile: you are not signed in, or the profile table is missing. The reading above still stands.';
  }
  return note;
}

class FoundationMatchScreen extends StatefulWidget {
  const FoundationMatchScreen({super.key});

  @override
  State<FoundationMatchScreen> createState() => _FoundationMatchScreenState();
}

class _FoundationMatchScreenState extends State<FoundationMatchScreen> {
  _Stage _stage = _Stage.intake;

  /// Non-null only in [_Stage.result] and [_Stage.retake].
  FoundationMatchResult? _result;

  /// A failure that stopped the run before the server saw it.
  String? _errorMessage;
  String? _errorHint;

  /// What the pipeline is doing, so a slow phone shows progress rather than a
  /// spinner that could mean anything.
  String _progressLabel = '';

  /// The last match, read from local storage on open. Lets the screen show a
  /// previous result with no network and no second photo.
  CachedFoundationMatch? _cached;

  /// Guards against a second tap while a run is in flight.
  bool _busy = false;

  final ImagePicker _picker = ImagePicker();

  /// Optional white-sheet path. Off unless the user turns it on.
  bool _havePaper = false;

  /// Gallery photos are labelled on the result so a weak reading is expected.
  bool _fromGallery = false;

  /// Names of the blush and lip the harmony helper would pair with this result.
  String? _harmonyBlushName;
  String? _harmonyLipName;
  int _harmonyTicket = 0;

  @override
  void initState() {
    super.initState();
    if (Supabase.instance.client.auth.currentSession == null) {
      _stage = _Stage.signIn;
    }
    _loadCached();
    unawaited(_recoverLostGallerySelection());
  }

  bool get _signedIn => Supabase.instance.client.auth.currentSession != null;

  void _showSignInGate() {
    setState(() {
      _busy = false;
      _stage = _Stage.signIn;
      _result = null;
      _errorMessage = null;
      _errorHint = null;
    });
  }

  /// Same sign-in route the profile button uses, on this navigator, so the
  /// try-on camera stays mounted underneath.
  Future<void> _openSignIn() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const AuthScreen(isLoginMode: true)),
    );
    if (!mounted) return;
    if (_signedIn) {
      setState(() {
        _stage = _Stage.intake;
        _errorMessage = null;
        _errorHint = null;
      });
    }
  }

  Future<void> _loadCached() async {
    final cached = await FoundationMatchService.cachedSummary();
    if (!mounted) return;
    setState(() => _cached = cached);
  }

  /// Android may destroy the activity while the system photo picker is open.
  /// image_picker keeps the result natively; recover it when this screen is
  /// recreated instead of leaving the user with a restarted app.
  Future<void> _recoverLostGallerySelection() async {
    try {
      final response = await _picker.retrieveLostData();
      if (!mounted || response.isEmpty) return;
      final files = response.files;
      if (files == null || files.isEmpty) {
        setState(() {
          _stage = _Stage.intake;
          _errorMessage = "Couldn't restore the selected photo.";
          _errorHint = 'Please choose the photo again.';
        });
        return;
      }
      await _matchPaths([files.first.path], fromGallery: true);
    } catch (e) {
      debugPrint('[FoundationMatch] lost picker data recovery failed: $e');
    }
  }

  // ── Run ────────────────────────────────────────────────────────────────────

  Future<void> _runGallery() async {
    if (_busy) return;
    XFile? picked;
    try {
      picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 92,
      );
    } catch (e) {
      debugPrint('[FoundationMatch] picker failed: $e');
      if (!mounted) return;
      setState(() {
        _stage = _Stage.intake;
        _errorMessage = "Couldn't open your photos.";
        _errorHint = 'Check the app permissions in Settings and try again.';
      });
      return;
    }
    if (picked == null || !mounted) return;
    await _matchPaths([picked.path], fromGallery: true);
  }

  bool _openingCapture = false;

  Future<void> _runCamera() async {
    if (_busy || _openingCapture) return;
    _openingCapture = true;
    try {
      final status = await Permission.camera.status;
      if (!mounted) return;
      if (!await CameraPermissionScreen.allowFeature(context, deviceGranted: status.isGranted)) return;
      if (mounted) await _captureFoundationPhoto();
    } finally {
      _openingCapture = false;
    }
  }

  Future<void> _captureFoundationPhoto() async {
    final captured = await Navigator.of(context).push<FoundationCaptureResult>(
      MaterialPageRoute(builder: (_) => const FoundationCaptureScreen()),
    );
    if (!mounted || captured == null) return;
    if (captured.chooseGallery) {
      await _runGallery();
      return;
    }
    if (captured.error != null) {
      setState(() {
        _stage = _Stage.intake;
        _errorMessage = captured.error;
        _errorHint = captured.hint ?? 'You can still choose a photo from your gallery.';
      });
      return;
    }
    final paths = captured.paths;
    if (paths == null || paths.isEmpty) return;
    await _matchPaths(paths, fromGallery: false);
  }

  Future<void> _matchPaths(List<String> paths, {required bool fromGallery}) async {
    setState(() {
      _busy = true;
      _fromGallery = fromGallery;
      _stage = _Stage.working;
      _errorMessage = null;
      _errorHint = null;
      _progressLabel = paths.length > 1 ? 'Reading a few frames…' : 'Finding your face…';
    });

    Future.delayed(const Duration(milliseconds: 700), () {
      if (mounted && _stage == _Stage.working) {
        setState(() => _progressLabel = 'Measuring your skin tone…');
      }
    });
    Future.delayed(const Duration(milliseconds: 1800), () {
      if (mounted && _stage == _Stage.working) {
        setState(() => _progressLabel = 'Comparing against every shade…');
      }
    });

    try {
      final sampled = await SkinSampler.sampleFrames(
        paths,
        seekWhiteReference: _havePaper,
        fromGallery: fromGallery,
        onFrameDiagnostics: kDebugMode
            ? (diagnostics) =>
                debugPrint('[FoundationMatch][diag] ${diagnostics.toString()}')
            : null,
        onFrameFailure: kDebugMode
            ? (frameNumber, reason) => debugPrint(
                  '[FoundationMatch][diag] frame=$frameNumber samplingFailed="$reason"',
                )
            : null,
      );
      if (!mounted) return;

      if (kDebugMode) {
        debugPrint(
          '[FoundationMatch][diag] sampled '
          'source=${fromGallery ? 'gallery' : 'camera'} '
          'frames=${paths.length} acceptedPatches=${sampled.patches.length} '
          'illuminant=${sampled.illuminant == null ? 'missing' : 'available'}',
        );
      }

      Map<String, int>? paper = sampled.whiteReference;
      if (_havePaper && paper == null) {
        paper = await Navigator.of(context).push<Map<String, int>>(
          MaterialPageRoute(builder: (_) => PaperTapScreen(imagePath: paths.first)),
        );
        if (!mounted) return;
      }

      final result = await FoundationMatchService.matchSample(
        sampled,
        finishPreference: BeautyProfileService.getCachedProfile()?.finishPreference,
        whiteReference: paper,
      );

      if (kDebugMode) {
        debugPrint(
          '[FoundationMatch][diag] serverResult '
          'needsRetake=${result.needsRetake} '
          'reason="${result.retakeReason ?? 'none'}" '
          'hint="${result.retakeHint ?? 'none'}" '
          'expectedError=${result.expectedError?.toStringAsFixed(2) ?? 'n/a'} '
          'confidence=${result.confidence.toStringAsFixed(2)} '
          'label=${result.confidenceLabel} calibration=${result.calibration} '
          'warnings=${result.warnings}',
        );
      }

      if (!mounted) return;

      setState(() {
        _busy = false;
        _result = result;
        _stage = _shouldRetake(result) ? _Stage.retake : _Stage.result;
      });
      _scheduleHarmonyPreview(result);

      if (result.savedToProfile) {
        _refreshBeautyProfileCache();
      }
      _loadCached();
    } on FoundationMatchException catch (e) {
      if (!mounted) return;
      if (e.needsSignIn) {
        _showSignInGate();
        return;
      }
      setState(() {
        _busy = false;
        _stage = _Stage.intake;
        _errorMessage = e.message;
        _errorHint = e.hint;
      });
    } on SkinSampleException catch (e) {
      if (kDebugMode) {
        debugPrint('[FoundationMatch][diag] samplingRejected reason="${e.message}"');
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _stage = _Stage.intake;
        _errorMessage = e.message;
        _errorHint = e.hint;
      });
    } catch (e, st) {
      debugPrint('[FoundationMatch] unexpected: $e\n$st');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _stage = _Stage.intake;
        _errorMessage = 'Something went wrong while matching your shade.';
        _errorHint = 'Please try again.';
      });
    } finally {
      if (!fromGallery) {
        for (final path in paths) {
          try {
            await File(path).delete();
          } catch (_) {}
        }
      }
    }
  }

  Future<void> _refreshBeautyProfileCache() async {
    try {
      final profile = await BeautyProfileService.fetchProfile();
      BeautyProfileService.setCachedProfile(profile);
    } catch (e) {
      // Purely an optimisation; the next profile screen open will pick it up.
      debugPrint('[FoundationMatch] profile cache refresh failed: $e');
    }
  }

  // ── Actions on a match ─────────────────────────────────────────────────────

  void _tryInAr(FoundationMatch match) {
    final nav = Navigator.of(context);
    if (!nav.canPop()) return;
    nav.pop(
      FoundationTryOnRequest(
        productKey: match.productKey,
        shadeKey: match.shadeKey,
        shadeName: '${match.productName} · ${match.shadeName}',
      ),
    );
  }

  void _wearLook(FoundationMatch match) {
    final skin = _result?.skin;
    final nav = Navigator.of(context);
    if (skin == null || !nav.canPop()) return;
    nav.pop(
      FoundationLookRequest(
        productKey: match.productKey,
        shadeKey: match.shadeKey,
        shadeName: match.shadeName,
        skinHex: skin.hex,
        undertone: shownUndertone(skin),
      ),
    );
  }

  void _scheduleHarmonyPreview(FoundationMatchResult result) {
    final skin = result.skin;
    final best = result.best;
    if (skin == null || best == null || _shouldRetake(result)) {
      _harmonyBlushName = null;
      _harmonyLipName = null;
      return;
    }
    final ticket = ++_harmonyTicket;
    _loadHarmonyNames(skin, ticket);
  }

  Future<void> _loadHarmonyNames(SkinReading skin, int ticket) async {
    try {
      final shades = await _readShadeMaps();
      if (!mounted || ticket != _harmonyTicket) return;
      final undertone = shownUndertone(skin);
      final blushShades = shades.where((s) => (s['product_key'] ?? '').toString().startsWith('blu_')).toList();
      var lipShades = shades.where((s) => (s['product_key'] ?? '').toString().startsWith('lip_')).toList();
      if (lipShades.isEmpty) {
        lipShades = shades.where((s) => (s['product_key'] ?? '').toString().startsWith('gloss_')).toList();
      }
      final blush = nearestHarmonyShade(
        shades: blushShades,
        skinHex: skin.hex,
        undertone: undertone,
        lip: false,
      );
      final lip = nearestHarmonyShade(
        shades: lipShades,
        skinHex: skin.hex,
        undertone: undertone,
        lip: true,
      );
      setState(() {
        _harmonyBlushName = blush?.shadeName;
        _harmonyLipName = lip?.shadeName;
      });
    } catch (e) {
      debugPrint('[FoundationMatch] harmony names failed: $e');
    }
  }

  /// Read-only. Never writes shade_hex or shade_key.
  /// Shows the disk copy immediately. A stale copy is refreshed in the background.
  Future<List<Map<String, dynamic>>> _readShadeMaps() async {
    try {
      final disk = await ShadeDiskCache.read();
      if (disk.shades.isNotEmpty) {
        if (!disk.isFreshAt(DateTime.now())) {
          unawaited(_refreshShadeDisk());
        }
        return disk.shades;
      }
    } catch (e) {
      debugPrint('[FoundationMatch] shade cache read failed: $e');
    }
    final rows = await _fetchShadeMaps();
    if (rows.isNotEmpty) {
      try {
        await ShadeDiskCache.write(rows, DateTime.now());
      } catch (e) {
        debugPrint('[FoundationMatch] shade cache write failed: $e');
      }
    }
    return rows;
  }

  Future<void> _refreshShadeDisk() async {
    final rows = await _fetchShadeMaps();
    if (rows.isEmpty) return;
    try {
      await ShadeDiskCache.write(rows, DateTime.now());
    } catch (e) {
      debugPrint('[FoundationMatch] shade cache write failed: $e');
    }
  }

  Future<List<Map<String, dynamic>>> _fetchShadeMaps() async {
    try {
      final rows = await Supabase.instance.client
          .from('product_shades')
          .select('product_key,shade_key,shade_name,shade_hex')
          .limit(2000);
      return (rows as List)
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
    } catch (e) {
      debugPrint('[FoundationMatch] shade list read failed: $e');
      return [];
    }
  }

  Future<void> _addToBag(FoundationMatch match) async {
    final bag = MakeupBagCache.instance;
    final already = bag.isInBag(match.productKey, match.shadeKey);
    if (already) {
      _toast('${match.shadeName} is already in your Makeup Bag.');
      return;
    }

    // `toggleInBag` is a toggle, so it is only ever called here after confirming
    // the item is absent — otherwise "Add to bag" would silently remove it.
    await bag.toggleInBag(match.productKey, match.shadeKey);
    if (!mounted) return;
    _toast('Added ${match.shadeName} to your Makeup Bag.');
  }

  Future<void> _buyOnWeb(FoundationMatch match) async {
    // Authenticated so the site opens signed in, and the product page can show
    // "in your bag" state consistently with the app.
    // The catalog page ignores ?product=. The product lives at /products/{key},
    // and that page preselects ?shade=.
    await WebBridge.openAuthenticated(
      context,
      AppConfig.productPagePath(match.productKey, shadeKey: match.shadeKey),
    );
  }

  /// Cross-region ΔE above this is an uneven photo, not a shade to wear.
  static const double _unevenDeltaE = 5;

  /// A stable reading still this far from every chip is not "your match".
  static const double _farCatalogDeltaE = 6;

  bool _shouldRetake(FoundationMatchResult result) {
    if (result.needsRetake) return true;
    final spread = result.expectedError;
    return spread != null && spread > _unevenDeltaE;
  }

  Future<void> _vote(String vote) async {
    try {
      final note = await FoundationMatchService.submitFeedback(vote);
      if (!mounted) return;
      _toast(note);
    } on FoundationMatchException catch (e) {
      if (!mounted) return;
      if (e.needsSignIn) {
        _showSignInGate();
        return;
      }
      _toast(e.hint == null ? e.message : '${e.message} ${e.hint}');
    }
  }

  Future<void> _shareDebugSample() async {
    final json = FoundationMatchService.debugRequestJson;
    if (json == null || json.isEmpty) {
      _toast('Take a photo first — there is no sample to copy yet.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    _toast('Sample copied. It has colours only, no photo.');
    try {
      await SharePlus.instance.share(
        ShareParams(text: json, subject: 'Foundation sample'),
      );
    } catch (e) {
      debugPrint('[FoundationMatch] share failed: $e');
    }
  }

  void _toast(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
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

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    AppColors.watch(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.chevron_left, color: AppColors.textMain),
          onPressed: _busy
              ? null
              : () {
                  final nav = Navigator.of(context);
                  if (nav.canPop()) nav.pop();
                },
        ),
        title: Text(
          'Find My Shade',
          style: TextStyle(
            color: AppColors.textMain,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.3,
          ),
        ),
        centerTitle: true,
        actions: [
          if (_stage == _Stage.result || _stage == _Stage.retake)
            IconButton(
              tooltip: 'Start again',
              icon: Icon(Icons.refresh_rounded, color: AppColors.primary),
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _stage = _Stage.intake;
                        _result = null;
                        _errorMessage = null;
                        _errorHint = null;
                      }),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: switch (_stage) {
          _Stage.signIn => _buildSignIn(),
          _Stage.intake => _buildIntake(),
          _Stage.working => _buildWorking(),
          _Stage.retake => _buildRetake(),
          _Stage.result => _buildResult(),
        },
      ),
    );
  }

  // ── Stage: sign in ─────────────────────────────────────────────────────────

  Widget _buildSignIn() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 36, 28, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Find My Shade',
            style: TextStyle(
              color: AppColors.textMain,
              fontSize: 26,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'This match is saved to your account, so you need to be signed in first.',
            style: TextStyle(color: AppColors.textMuted, fontSize: 15.5, height: 1.45),
          ),
          const SizedBox(height: 28),
          _PrimaryButton(
            icon: Icons.login_rounded,
            label: 'Sign in',
            onTap: _openSignIn,
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () {
              final nav = Navigator.of(context);
              if (nav.canPop()) nav.pop();
            },
            child: Text('Not now', style: TextStyle(color: AppColors.textMuted)),
          ),
        ],
      ),
    );
  }

  // ── Stage: intake ──────────────────────────────────────────────────────────

  Widget _buildIntake() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      physics: const BouncingScrollPhysics(),
      children: [
        const _HeroBlurb(),
        const SizedBox(height: 24),

        if (_errorMessage != null) ...[
          _NoticeCard(
            icon: Icons.error_outline_rounded,
            tone: _NoticeTone.error,
            title: _errorMessage!,
            body: _errorHint,
          ),
          const SizedBox(height: 20),
        ],

        _SectionLabel('For an accurate result'),
        const SizedBox(height: 12),        const _TipRow(
          icon: Icons.face_retouching_off_rounded,
          title: 'Bare skin',
          body:
              'No foundation, concealer or powder. Otherwise the match is made '
              'against the makeup you are already wearing, not your skin.',
        ),
        const _TipRow(
          icon: Icons.wb_sunny_outlined,
          title: 'Daylight, facing a window',
          body:
              'Warm bulbs shift your skin more than the gap between two '
              'neighbouring shades. Photos taken under one are rejected.',
        ),
        const _TipRow(
          icon: Icons.auto_fix_off_rounded,
          title: 'No filters or beauty mode',
          body: 'Smoothing changes the colour it smooths.',
        ),
        const _TipRow(
          icon: Icons.center_focus_strong_rounded,
          title: 'Face straight on, hair back',
          body: 'Forehead, both cheeks and jaw all need to be visible.',
        ),
        const SizedBox(height: 16),
        Text(
          'Your photo is measured on this phone and is not uploaded. '
          'Colour numbers are sent to match a shade, and that reading can be '
          'saved on this phone and to your profile.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 13, height: 1.4),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => WebBridge.openPublic(context, AppConfig.privacyPath),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text('Privacy', style: TextStyle(color: AppColors.primary)),
          ),
        ),

        const SizedBox(height: 28),
        _PrimaryButton(
          icon: Icons.photo_camera_rounded,
          label: 'Take a photo',
          onTap: _busy ? null : _runCamera,
        ),
        const SizedBox(height: 12),
        _SecondaryButton(
          icon: Icons.photo_library_outlined,
          label: 'Choose from gallery',
          onTap: _busy ? null : _runGallery,
        ),
        const SizedBox(height: 8),
        Text(
          'Gallery photos are less reliable. The matcher lowers confidence when it cannot see the light.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 12.5, height: 1.4),
        ),
        const SizedBox(height: 16),
        CheckboxListTile(
          value: _havePaper,
          onChanged: _busy
              ? null
              : (v) => setState(() => _havePaper = v ?? false),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          activeColor: AppColors.primary,
          title: Text(
            'I have a white sheet of paper',
            style: TextStyle(color: AppColors.textMain, fontSize: 14.5, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            'Optional. Hold it beside your cheek in the same light. Skip this if you don\'t have one.',
            style: TextStyle(color: AppColors.textMuted, fontSize: 12.5, height: 1.35),
          ),
        ),

        const SizedBox(height: 24),
        const _PrivacyNote(),

        if (_cached != null) ...[
          const SizedBox(height: 28),
          _SectionLabel('Your last match'),
          const SizedBox(height: 12),
          _CachedMatchCard(
            cached: _cached!,
            onRerank: _busy ? null : _rerankFromCache,
          ),
        ],
      ],
    );
  }

  /// Re-ranks the catalog against the stored tone. No camera, no sampling — used
  /// when the catalog may have changed since the photo was taken.
  Future<void> _rerankFromCache() async {
    final cached = _cached;
    if (cached == null) return;

    setState(() {
      _busy = true;
      _stage = _Stage.working;
      _progressLabel = 'Comparing against every shade…';
    });

    try {
      final result = await FoundationMatchService.matchFromSkinHex(
        cached.skinHex,
        finishPreference: BeautyProfileService.getCachedProfile()?.finishPreference,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _result = result;
        _stage = _shouldRetake(result) ? _Stage.retake : _Stage.result;
      });
      _scheduleHarmonyPreview(result);
    } on FoundationMatchException catch (e) {
      if (!mounted) return;
      if (e.needsSignIn) {
        _showSignInGate();
        return;
      }
      setState(() {
        _busy = false;
        _stage = _Stage.intake;
        _errorMessage = e.message;
        _errorHint = e.hint;
      });
    } catch (e) {
      debugPrint('[FoundationMatch] rerank failed: $e');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _stage = _Stage.intake;
        _errorMessage = 'Could not refresh your matches.';
        _errorHint = 'Please try again.';
      });
    }
  }

  // ── Stage: working ─────────────────────────────────────────────────────────

  Widget _buildWorking() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 46,
              height: 46,
              child: AppLoader(size: 46, strokeWidth: 3),
            ),
            const SizedBox(height: 28),
            Text(
              _progressLabel,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textMain,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Your photo never leaves this device.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  // ── Stage: retake ──────────────────────────────────────────────────────────

  Widget _buildRetake() {
    final result = _result;
    final serverReason = result?.retakeReason?.trim();
    final hasServerReason = serverReason != null && serverReason.isNotEmpty;
    final spreadIsHigh =
        result?.expectedError != null && result!.expectedError! > _unevenDeltaE;
    final normalizedServerReason = serverReason?.toLowerCase() ?? '';
    final isRegionMismatch =
        spreadIsHigh ||
        normalizedServerReason.contains('region') ||
        normalizedServerReason.contains('δe') ||
        normalizedServerReason.contains('delta e');
    final reason = isRegionMismatch
        ? 'The colour looks different across parts of your face, so we can’t '
            'match it reliably from this photo.'
        : hasServerReason
            ? serverReason
            : 'That photo could not be measured.';
    final serverHint = result?.retakeHint?.trim();
    final hint = isRegionMismatch
        ? 'Try again facing a window or evenly lit area. Keep your face straight '
            'and avoid light coming from just one side.'
        : serverHint != null && serverHint.isNotEmpty
            ? serverHint
            : 'Take another photo in even daylight, facing a window.';
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
      physics: const BouncingScrollPhysics(),
      children: [
        Text(
          reason,
          style: TextStyle(
            color: AppColors.textMain,
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          hint,
          style: TextStyle(color: AppColors.textMuted, fontSize: 15, height: 1.45),
        ),
        const SizedBox(height: 28),
        _PrimaryButton(
          icon: Icons.photo_camera_rounded,
          label: 'Take another photo',
          onTap: _busy ? null : _runCamera,
        ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: _busy ? null : _runGallery,
          child: Text('Choose from gallery', style: TextStyle(color: AppColors.textMuted)),
        ),
      ],
    );
  }

  // ── Stage: result ──────────────────────────────────────────────────────────

  Widget _buildResult() {
    final result = _result;
    final skin = result?.skin;
    if (result == null || skin == null) {
      return _buildIntake();
    }

    final best = result.best;
    final closeEnough = best != null && best.deltaE <= _farCatalogDeltaE;
    final good = closeEnough && !_fromGallery;
    final shown = <FoundationMatch>[
      if (best != null && (good || (_fromGallery && closeEnough))) best,
      if (best != null && !(good || (_fromGallery && closeEnough))) ...result.matches.take(2),
    ];
    final status = good ? 'Your closest shade.' : 'Nearest shade we have.';
    final sentence = _fromGallery
        ? 'A gallery photo is less reliable.'
        : good
            ? 'In even daylight this is usually this shade, or the one just beside it.'
            : 'This is the closest colour in the catalog. It is not a close match, so try it in AR before you rely on it.';
    final saveLine = (!result.savedToProfile && result.persistenceNotes.isNotEmpty)
        ? _persistenceLine(result.persistenceNotes.first)
        : null;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      physics: const BouncingScrollPhysics(),
      children: [
        Text(
          status,
          style: TextStyle(
            color: AppColors.textMain,
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          sentence,
          style: TextStyle(color: AppColors.textMuted, fontSize: 14.5, height: 1.4),
        ),
        const SizedBox(height: 16),
        if (shown.isEmpty)
          Text(
            'No foundation shades are in the shop catalog yet, so there is no product to recommend.',
            style: TextStyle(color: AppColors.textMain, fontSize: 15, height: 1.4),
          )
        else if (shown.length == 1)
          _ShortShadeCard(
            match: shown.first,
            onTryInAr: () => _tryInAr(shown.first),
            onAddToBag: () => _addToBag(shown.first),
            onBuy: () => _buyOnWeb(shown.first),
            onWearLook: () => _wearLook(shown.first),
          )
        else
          ...shown.map(
            (m) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _ShortShadeCard(
                match: m,
                onTryInAr: () => _tryInAr(m),
                onAddToBag: () => _addToBag(m),
                onBuy: () => _buyOnWeb(m),
                onWearLook: () => _wearLook(m),
                compact: true,
              ),
            ),
          ),
        if (shown.isNotEmpty) ...[
          if (_harmonyBlushName != null || _harmonyLipName != null) ...[
            const SizedBox(height: 8),
            Text(
              [
                if (_harmonyBlushName != null) 'Blush: $_harmonyBlushName',
                if (_harmonyLipName != null) 'Lip: $_harmonyLipName',
              ].join(' · '),
              style: TextStyle(
                color: AppColors.textMain,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            harmonySuggestionNote,
            style: TextStyle(color: AppColors.textMuted, fontSize: 12.5, height: 1.35),
          ),
        ],
        if (good) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (result.lighterAlternate != null)
                _NameChip(result.lighterAlternate!.shadeName),
              if (result.deeperAlternate != null)
                _NameChip(result.deeperAlternate!.shadeName),
            ],
          ),
        ],
        if (shown.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            'Your vote is saved for later and does not change today\'s shade.',
            style: TextStyle(color: AppColors.textMuted, fontSize: 12.5, height: 1.35),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _VoteButton(label: 'Too light', onTap: () => _vote('too_light'))),
              const SizedBox(width: 8),
              Expanded(child: _VoteButton(label: 'Looks right', onTap: () => _vote('right'))),
              const SizedBox(width: 8),
              Expanded(child: _VoteButton(label: 'Too dark', onTap: () => _vote('too_dark'))),
            ],
          ),
        ],
        if (saveLine != null) ...[
          const SizedBox(height: 10),
          Text(
            saveLine,
            style: TextStyle(color: AppColors.textMuted, fontSize: 12, height: 1.35),
          ),
        ],
        const SizedBox(height: 4),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            title: Text(
              'How this was measured',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            children: [
              _SkinReadingCard(skin: skin, result: result),
              if (result.catalogNotes.isNotEmpty) ...[
                const SizedBox(height: 8),
                ...result.catalogNotes.map((n) => _BulletLine(n)),
              ],
            ],
          ),
        ),
        if (kDebugMode)
          _SecondaryButton(
            icon: Icons.ios_share_rounded,
            label: 'Copy sample JSON',
            onTap: _shareDebugSample,
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Measured-skin card
// ─────────────────────────────────────────────────────────────────────────────

class _SkinReadingCard extends StatelessWidget {
  const _SkinReadingCard({required this.skin, required this.result});

  final SkinReading skin;
  final FoundationMatchResult result;

  @override
  Widget build(BuildContext context) {
    final swatch = Color(0xFF000000 | skin.packedColour);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  color: swatch,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.neutral300, width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: swatch.withValues(alpha: 0.35),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Your skin tone',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      skin.hex.toUpperCase(),
                      style: TextStyle(
                        color: AppColors.textMain,
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(height: 6),
                    _ConfidencePill(
                      label: result.confidenceLabel,
                      score: result.confidence,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      result.calibration,
                      style: TextStyle(
                        color: result.calibration == 'Calibrated'
                            ? Colors.green.shade700
                            : AppColors.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (skin.depthLevel.isNotEmpty)
                _Chip(_titleCase(skin.depthLevel), Icons.brightness_6_outlined),
              if (shownUndertone(skin).isNotEmpty)
                _Chip('${_titleCase(shownUndertone(skin))} undertone',
                    Icons.opacity_outlined),
              if (skin.monkScale > 0)
                _Chip('Monk ${skin.monkScale}', Icons.straighten_rounded),
              _Chip('ITA ${skin.ita.toStringAsFixed(1)}°',
                  Icons.architecture_outlined),
            ],
          ),
          const SizedBox(height: 14),
          Divider(color: AppColors.border, height: 1),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.science_outlined, size: 15, color: AppColors.neutral500),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _provenance(),
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
          if (result.savedToProfile)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  Icon(Icons.check_circle_outline_rounded,
                      size: 15, color: Colors.green.shade600),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Saved to your Beauty Profile.',
                      style: TextStyle(
                        color: Colors.green.shade600,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Where the number came from. Shown because a colour with no provenance is a
  /// colour the user has no reason to believe.
  String _provenance() {
    final regions = skin.regionsUsed;
    final labelled = regions.map(_regionLabel).toList();
    final lab = 'L* ${skin.l.toStringAsFixed(1)} · '
        'a* ${skin.a.toStringAsFixed(1)} · '
        'b* ${skin.b.toStringAsFixed(1)}';
    if (labelled.isEmpty) return 'CIELAB $lab';
    final joined = labelled.length == 1
        ? labelled.first
        : '${labelled.take(labelled.length - 1).join(', ')} and ${labelled.last}';
    return 'Measured from your $joined, white-balanced, then converted to '
        'CIELAB $lab.';
  }

  static String _regionLabel(String region) => switch (region) {
        'forehead' => 'forehead',
        'left_cheek' => 'left cheek',
        'right_cheek' => 'right cheek',
        'jaw' => 'jaw',
        'nose_bridge' => 'nose bridge',
        _ => region.replaceAll('_', ' '),
      };
}

// ─────────────────────────────────────────────────────────────────────────────
// Short shade card
// ─────────────────────────────────────────────────────────────────────────────

class _ShortShadeCard extends StatelessWidget {
  const _ShortShadeCard({
    required this.match,
    required this.onTryInAr,
    required this.onAddToBag,
    required this.onBuy,
    required this.onWearLook,
    this.compact = false,
  });

  final FoundationMatch match;
  final VoidCallback onTryInAr;
  final VoidCallback onAddToBag;
  final VoidCallback onBuy;
  final VoidCallback onWearLook;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final swatch = Color(0xFF000000 | match.packedColour);
    final brandLine = [
      if (match.brand != null && match.brand!.isNotEmpty) match.brand!,
      match.productName,
    ].join(' · ');

    if (compact) {
      return Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                onTap: onTryInAr,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: swatch,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.neutral300),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              match.shadeName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppColors.textMain,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              brandLine,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Add to bag',
                        visualDensity: VisualDensity.compact,
                        icon: Icon(Icons.add_shopping_cart_rounded, size: 19, color: AppColors.primary),
                        onPressed: onAddToBag,
                      ),
                    ],
                  ),
                ),
              ),
              TextButton(
                onPressed: onWearLook,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: AppColors.primary,
                  alignment: Alignment.centerLeft,
                ),
                child: const Text(
                  'Wear a look with this shade',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 84,
            decoration: BoxDecoration(
              color: swatch,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(15)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  match.shadeName,
                  style: TextStyle(
                    color: AppColors.textMain,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  brandLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppColors.neutral700, fontSize: 13.5),
                ),
                const SizedBox(height: 12),
                _PrimaryButton(
                  icon: Icons.auto_awesome_rounded,
                  label: 'Try in AR',
                  onTap: onTryInAr,
                ),
                const SizedBox(height: 8),
                _SecondaryButton(
                  icon: Icons.face_retouching_natural_rounded,
                  label: 'Wear a look with this shade',
                  onTap: onWearLook,
                  dense: true,
                ),
                const SizedBox(height: 8),
                _SecondaryButton(
                  icon: Icons.shopping_bag_outlined,
                  label: 'Add to bag',
                  onTap: onAddToBag,
                  dense: true,
                ),
                if (match.productKey.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: onBuy,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 0),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        foregroundColor: AppColors.textMuted,
                      ),
                      child: const Text('Buy on web', style: TextStyle(fontSize: 13)),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NameChip extends StatelessWidget {
  const _NameChip(this.name);

  final String name;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border),
      ),
      child: Text(
        name,
        style: TextStyle(color: AppColors.textMain, fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
    );
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// Cached-match card
// ─────────────────────────────────────────────────────────────────────────────

class _CachedMatchCard extends StatelessWidget {
  const _CachedMatchCard({required this.cached, required this.onRerank});

  final CachedFoundationMatch cached;
  final VoidCallback? onRerank;

  @override
  Widget build(BuildContext context) {
    final swatch = Color(0xFF000000 | cached.packedSkinColour);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: swatch,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.neutral300),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cached.shadeLabel ?? cached.skinHex.toUpperCase(),
                      maxLines: 2,
                      style: TextStyle(
                        color: AppColors.textMain,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (cached.deltaE != null || cached.measuredAt != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          [
                            if (cached.deltaE != null)
                              'ΔE ${cached.deltaE!.toStringAsFixed(1)}',
                            if (cached.measuredAt != null)
                              _ago(cached.measuredAt!),
                          ].join(' · '),
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _SecondaryButton(
            icon: Icons.refresh_rounded,
            label: 'Re-check against the catalog',
            onTap: onRerank,
            dense: true,
          ),
        ],
      ),
    );
  }

  static String _ago(DateTime when) {
    final d = DateTime.now().difference(when);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    if (d.inDays < 30) return '${d.inDays}d ago';
    return '${(d.inDays / 30).floor()}mo ago';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Small pieces
// ─────────────────────────────────────────────────────────────────────────────

class _HeroBlurb extends StatelessWidget {
  const _HeroBlurb();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.primary.withValues(alpha: 0.14),
            AppColors.secondary.withValues(alpha: 0.16),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.colorize_rounded, color: AppColors.primary, size: 20),
              const SizedBox(width: 10),
              Text(
                'Foundation shade match',
                style: TextStyle(
                  color: AppColors.textMain,
                  fontSize: 16.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'One photo. Your skin is measured at five points on your face, '
            'corrected for the light in the room, and compared to every '
            'foundation shade in the catalog by perceptual colour distance.',
            style: TextStyle(
              color: AppColors.neutral700,
              fontSize: 13.5,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.lock_outline_rounded, size: 15, color: AppColors.neutral500),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Your photo is analysed on this phone and never uploaded. Only the '
            'measured colours are sent — about forty numbers, no image.',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 12,
              height: 1.45,
            ),
          ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        color: AppColors.textMuted,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.0,
      ),
    );
  }
}

class _TipRow extends StatelessWidget {
  const _TipRow({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 17, color: AppColors.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: AppColors.textMain,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum _NoticeTone { info, warning, error }

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.icon,
    required this.tone,
    required this.title,
    this.body,
  });

  final IconData icon;
  final _NoticeTone tone;
  final String title;
  final String? body;

  @override
  Widget build(BuildContext context) {
    final colour = switch (tone) {
      _NoticeTone.info => AppColors.primary,
      _NoticeTone.warning => const Color(0xFFD98324),
      _NoticeTone.error => AppColors.error,
    };

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colour.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 19, color: colour),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: AppColors.textMain,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
                if (body != null && body!.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(
                    body!,
                    style: TextStyle(
                      color: AppColors.neutral700,
                      fontSize: 12.5,
                      height: 1.45,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BulletLine extends StatelessWidget {
  const _BulletLine(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5, right: 8),
            child: Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.neutral500,
                shape: BoxShape.circle,
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label, this.icon);
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.neutral200,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: AppColors.neutral700),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: AppColors.neutral700,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _ConfidencePill extends StatelessWidget {
  const _ConfidencePill({required this.label, required this.score});

  final String label;
  final double score;

  @override
  Widget build(BuildContext context) {
    final colour = switch (label) {
      'high' => const Color(0xFF2E9E5B),
      'moderate' => const Color(0xFFD98324),
      _ => AppColors.error,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colour.withValues(alpha: 0.30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            '${_titleCase(label)} confidence · ${(score * 100).round()}%',
            style: TextStyle(
              color: colour,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: AppColors.neutral300,
          padding: const EdgeInsets.symmetric(vertical: 15),
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  const _SecondaryButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.dense = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: dense ? 15 : 17),
        label: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.primary,
          disabledForegroundColor: AppColors.neutral500,
          side: BorderSide(color: AppColors.primary.withValues(alpha: 0.4)),
          padding: EdgeInsets.symmetric(vertical: dense ? 11 : 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: TextStyle(
            fontSize: dense ? 13 : 14.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _VoteButton extends StatelessWidget {
  const _VoteButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.textMain,
        side: BorderSide(color: AppColors.border),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
      child: Text(label, textAlign: TextAlign.center),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Utilities
// ─────────────────────────────────────────────────────────────────────────────

String _titleCase(String s) {
  if (s.isEmpty) return s;
  return s[0].toUpperCase() + s.substring(1);
}
