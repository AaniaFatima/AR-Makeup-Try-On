import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:camera/camera.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'makeup_painter.dart';
import 'dart:math' as math;

Uint8List yuv420ToNv21(CameraImage image) {
  final int width = image.width;
  final int height = image.height;

  final Uint8List yPlane = image.planes[0].bytes;
  final Uint8List uPlane = image.planes[1].bytes;
  final Uint8List vPlane = image.planes[2].bytes;

  final int yRowStride = image.planes[0].bytesPerRow;

  final int uRowStride = image.planes[1].bytesPerRow;
  final int vRowStride = image.planes[2].bytesPerRow;

  final int uvPixelStride = image.planes[1].bytesPerPixel ?? 1;

  final out = Uint8List(width * height + (width * height ~/ 2));

  int pos = 0;

  // Y
  for (int row = 0; row < height; row++) {
    final int start = row * yRowStride;
    out.setRange(pos, pos + width, yPlane, start);
    pos += width;
  }

  // VU (NV21)
  final int uvHeight = height ~/ 2;
  final int uvWidth = width ~/ 2;

  for (int row = 0; row < uvHeight; row++) {
    final int uRowStart = row * uRowStride;
    final int vRowStart = row * vRowStride;

    for (int col = 0; col < uvWidth; col++) {
      final int uvOffset = col * uvPixelStride;

      out[pos++] = vPlane[vRowStart + uvOffset]; // V
      out[pos++] = uPlane[uRowStart + uvOffset]; // U
    }
  }

  return out;
}

// Downsample NV21 by factor of 2 — 4x less data for faster face detection
Uint8List downsampleNv21(Uint8List nv21, int width, int height) {
  final int newW = width ~/ 2;
  final int newH = height ~/ 2;
  final out = Uint8List(newW * newH + (newW * newH ~/ 2));
  int pos = 0;

  // Downsample Y plane
  for (int row = 0; row < newH; row++) {
    for (int col = 0; col < newW; col++) {
      out[pos++] = nv21[(row * 2) * width + (col * 2)];
    }
  }

  // Downsample UV plane
  final int uvStart = width * height;
  final int newUvH = newH ~/ 2;
  final int newUvW = newW ~/ 2;
  for (int row = 0; row < newUvH; row++) {
    for (int col = 0; col < newUvW; col++) {
      final int srcIdx = uvStart + (row * 2) * (width ~/ 2) * 2 + (col * 2) * 2;
      if (srcIdx + 1 < nv21.length) {
        out[pos++] = nv21[srcIdx]; // V
        out[pos++] = nv21[srcIdx + 1]; // U
      } else {
        out[pos++] = 128;
        out[pos++] = 128;
      }
    }
  }

  return out;
}

class DbShade {
  final String productKey;
  final String shadeName;
  final String shadeHex;
  final int shadeOrder;
  final String shadeKey;

  DbShade({
    required this.productKey,
    required this.shadeName,
    required this.shadeHex,
    required this.shadeOrder,
    required this.shadeKey,
  });

  factory DbShade.fromMap(Map<String, dynamic> map) {
    return DbShade(
      productKey: map['product_key'] as String? ?? '',
      shadeName: map['shade_name'] as String? ?? '',
      shadeHex: map['shade_hex'] as String? ?? '#D81B60',
      shadeOrder: (map['shade_order'] as num?)?.toInt() ?? 0,
      shadeKey: map['shade_key'] as String? ?? '',
    );
  }

  Color get color {
    final cleaned = shadeHex.replaceAll('#', '').trim();
    return Color(int.parse('FF$cleaned', radix: 16));
  }
}

class TryOnScreen extends StatefulWidget {
  const TryOnScreen({super.key});

  @override
  State<TryOnScreen> createState() => _TryOnScreenState();
}

class _TryOnScreenState extends State<TryOnScreen> with WidgetsBindingObserver {
  CameraController? _camera;
  bool _initializing = true;
  bool _cameraError = false;
  final List<List<Map<String, double>>> _faces = [];
  bool _isFrontCamera = true;

  static const MethodChannel _channel = MethodChannel('makeup_tryon/face_mesh');

  bool _isProcessing = false;

  static const int _frameStride = 1; // detect every frame
  int _frameCount = 0;

  int _lastProcessedMs = 0;

  // UI State
  TryOnCategory _category = TryOnCategory.lipstick;

  // Each category remembers its own shade and intensity independently
  final Map<TryOnCategory, Color> _categoryShades = {};
  final Map<TryOnCategory, double> _categoryIntensities = {};

  // Convenience getters for current category
  Color get _selectedShade => _categoryShades[_category] ?? Colors.transparent;
  double get _intensity => _categoryIntensities[_category] ?? 0.7;

  // ValueNotifiers
  late final ValueNotifier<List<List<Map<String, double>>>> _facesNotifier =
      ValueNotifier([]);
  // Single notifier with full map — MakeupPainter draws all at once
  late final ValueNotifier<Map<String, Color>> _allShadesNotifier =
      ValueNotifier({});
  late final ValueNotifier<Map<String, double>> _allIntensitiesNotifier =
      ValueNotifier({});

  List<DbShade> _allDbShades = [];
  bool _isLoadingShades = false;
  String? _shadesError;
  bool _isSaving = false;
  final GlobalKey _makeupKey = GlobalKey();

  int _rotationDegreesFor(CameraController controller) {
    final int sensor = controller.description.sensorOrientation;
    final DeviceOrientation device = controller.value.deviceOrientation;

    int deviceDeg;
    switch (device) {
      case DeviceOrientation.portraitUp:
        deviceDeg = 0;
        break;
      case DeviceOrientation.landscapeLeft:
        deviceDeg = 90;
        break;
      case DeviceOrientation.portraitDown:
        deviceDeg = 180;
        break;
      case DeviceOrientation.landscapeRight:
        deviceDeg = 270;
        break;
    }

    final bool front =
        controller.description.lensDirection == CameraLensDirection.front;

    final int rotation = front
        ? (sensor + deviceDeg) % 360
        : (sensor - deviceDeg + 360) % 360;

    return rotation;
  }

  String _prefixForCategory(TryOnCategory category) {
    switch (category) {
      case TryOnCategory.lipstick:
        return 'lip_';
      case TryOnCategory.blush:
        return 'blu_';
      case TryOnCategory.eyeshadow:
        return 'esh_';
      case TryOnCategory.eyeliner:
        return 'eln_';
      case TryOnCategory.foundation:
        return 'fnd_';
      case TryOnCategory.highlighter:
        return 'hgl_';
    }
  }

  // Converts TryOnCategory map → String map for MakeupPainter
  Map<String, Color> _buildShadesMap() {
    return {for (final e in _categoryShades.entries) e.key.name: e.value};
  }

  Map<String, double> _buildIntensitiesMap() {
    return {for (final e in _categoryIntensities.entries) e.key.name: e.value};
  }

  List<DbShade> get _filteredDbShades {
    final prefix = _prefixForCategory(_category);

    final shades =
        _allDbShades.where((s) => s.productKey.startsWith(prefix)).toList()
          ..sort((a, b) => a.shadeOrder.compareTo(b.shadeOrder));

    return shades;
  }

  Future<void> _loadShadesFromDb() async {
    setState(() {
      _isLoadingShades = true;
      _shadesError = null;
    });

    try {
      final response = await Supabase.instance.client
          .from('product_shades')
          .select('product_key, shade_name, shade_hex, shade_order, shade_key')
          .order('shade_order', ascending: true);

      final rows = response as List<dynamic>;

      _allDbShades = rows
          .map((e) => DbShade.fromMap(e as Map<String, dynamic>))
          .toList();

      final initialLipShades =
          _allDbShades.where((s) => s.productKey.startsWith('lip_')).toList()
            ..sort((a, b) => a.shadeOrder.compareTo(b.shadeOrder));

      setState(() {
        _isLoadingShades = false;
        if (initialLipShades.isNotEmpty) {
          _categoryShades[TryOnCategory.lipstick] =
              initialLipShades.first.color;
          _categoryIntensities[TryOnCategory.lipstick] = 0.7;
          _allShadesNotifier.value = _buildShadesMap();
          _allIntensitiesNotifier.value = _buildIntensitiesMap();
        }
      });
    } catch (e) {
      setState(() {
        _isLoadingShades = false;
        _shadesError = e.toString();
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
    _loadShadesFromDb();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopCamera();
    _facesNotifier.dispose();
    _allShadesNotifier.dispose();
    _allIntensitiesNotifier.dispose();
    super.dispose();
  }

  Future<void> _stopCamera() async {
    final controller = _camera;
    if (controller == null) return;

    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (_) {}

    try {
      await controller.dispose();
    } catch (_) {}

    _camera = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _stopCamera();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    setState(() {
      _initializing = true;
      _cameraError = false;
    });

    try {
      final cams = await availableCameras();
      final frontCam = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cams.first,
      );

      _isFrontCamera = frontCam.lensDirection == CameraLensDirection.front;

      final controller = CameraController(
        frontCam,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await controller.initialize();
      await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
      await controller.startImageStream(_onCameraFrame);

      if (!mounted) return;
      setState(() {
        _camera = controller;
        _initializing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cameraError = true;
        _initializing = false;
      });
    }
  }

  Future<void> _onCameraFrame(CameraImage image) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastProcessedMs < 16) return; // ~60fps
    _lastProcessedMs = now;

    _frameCount++;
    if (_frameCount % _frameStride != 0) return;

    if (_isProcessing) return;
    _isProcessing = true;

    try {
      final camera = _camera;
      if (camera == null) return;

      final nv21Full = yuv420ToNv21(image);
      final rot = _rotationDegreesFor(camera);

      // Downsample for detection → 4x faster, preview stays high quality
      final int detW = image.width ~/ 2;
      final int detH = image.height ~/ 2;
      final nv21 = downsampleNv21(nv21Full, image.width, image.height);

      final result = await _channel.invokeMethod('detect', {
        'bytes': nv21,
        'width': detW,
        'height': detH,
        'rotationDegrees': rot,
      });

      if (!mounted) return;

      final facesRaw = (result as Map?)?['faces'];

      if (facesRaw is List && facesRaw.isNotEmpty) {
        final parsed = facesRaw
            .map<List<Map<String, double>>>(
              (face) => (face as List)
                  .map<Map<String, double>>(
                    (p) => {
                      'x': (p['x'] as num).toDouble(),
                      'y': (p['y'] as num).toDouble(),
                      'z': (p['z'] as num).toDouble(),
                    },
                  )
                  .toList(),
            )
            .toList();

        // ── Anchor-relative lip smoothing ─────────────────────────────────
        // Problem: raw landmarks jitter per-frame → lipstick shakes
        // Solution: compute lip positions RELATIVE to stable anchor (nose/chin)
        //   → head movement: anchor moves instantly → lipstick follows perfectly
        //   → detection jitter: smoothed out in relative-space only
        final prev = _facesNotifier.value;
        final stabilized = _instantExpressionLips(parsed, prev);

        _facesNotifier.value = stabilized;
        _faces
          ..clear()
          ..addAll(stabilized);
      } else {
        if (_facesNotifier.value.isNotEmpty) {
          _facesNotifier.value = [];
          _faces.clear();
        }
      }
    } catch (e) {
      debugPrint('FaceMesh error: $e');
    } finally {
      _isProcessing = false;
    }
  }

  // ── Lip landmark indices (all points used in _drawLipstick) ───────────────
  static const _lipIndices = {
    // outer upper + lower
    61, 185, 40, 39, 37, 0, 267, 269, 270, 409, 291,
    146, 91, 181, 84, 17, 314, 405, 321, 375,
    // inner upper + lower
    78, 191, 80, 81, 82, 13, 312, 311, 310, 415, 308,
    95, 88, 178, 87, 14, 317, 402, 318, 324,
  };

  // Average x/y of given landmark points
  static Map<String, double> _avgPts(
    List<Map<String, double>> face,
    List<int> indices,
  ) {
    double x = 0, y = 0;
    for (final i in indices) {
      x += face[i]['x']!;
      y += face[i]['y']!;
    }
    return {'x': x / indices.length, 'y': y / indices.length};
  }

  /// Anchor-relative lip smoothing:
  ///   1. Anchor = midpoint of nose-tip (1) + chin (152) + nose-bottom (4)
  ///   2. Compute lip offsets FROM anchor in new & prev frames
  ///   3. Smooth only the OFFSETS (removes jitter, not head movement)
  ///   4. Reconstruct: new_anchor + smoothed_offset → instant head-follow + stable lips
  /// Advanced Adaptive Smoothing (Inspired by 1-Euro Filter)
  /// Fixes the 2-3 second delay and stops flickering.
  /// PRO ADAPTIVE SMOOTHING (Zero-Lag for Mouth Opening)
  /// PREDICTIVE TRACKING (Lag Compensation)
  /// Ye agle frame ki position predict karta hai taake lag khatam ho jaye.
  /// ULTIMATE SMOOTHING (Deadzone + Aggressive Prediction)
  /// 1. Deadzone: Kills 100% jitter when face is still.
  /// 2. Prediction: Kills remaining delay when moving.
  /// INSTANT EXPRESSION LOGIC (Zero Settling Time)
  static List<List<Map<String, double>>> _instantExpressionLips(
    List<List<Map<String, double>>> parsed,
    List<List<Map<String, double>>> prev,
  ) {
    if (prev.isEmpty || prev.length != parsed.length) return parsed;

    return List.generate(parsed.length, (fi) {
      final face = parsed[fi];
      final prevFace = prev[fi];
      if (face.length < 468 || prevFace.length < 468) return face;

      return List.generate(face.length, (pi) {
        // Sirf lips ke points ko process karein
        if (!_lipIndices.contains(pi)) return face[pi];
        if (pi >= prevFace.length) return face[pi];

        final cx = face[pi]['x']!;
        final cy = face[pi]['y']!;
        final px = prevFace[pi]['x']!;
        final py = prevFace[pi]['y']!;

        final dx = cx - px;
        final dy = cy - py;
        final dist = math.sqrt(dx * dx + dy * dy);

        double alpha;

        // THE INSTANT SNAP LOGIC:
        if (dist < 0.0004) {
          // 1. Micro-Jitter (Bilkul still face):
          // Sirf camera ke noise ko lock karne ke liye halki smoothing.
          alpha = 0.3;
        } else if (dist > 0.0012) {
          // 2. ANY Expression (Smile, Talk, Open Mouth):
          // Jaise hi lips thora sa bhi move honge, Alpha = 1.0 ho jayega.
          // Iska matlab hai ZERO smoothing, ZERO settling time.
          // Lipstick fauran nayi shape par snap karegi!
          alpha = 1.0;
        } else {
          // 3. Smooth transition zone (boht chota rakha hai taake delay na aaye)
          alpha = 0.3 + ((dist - 0.0004) / 0.0008) * 0.7;
        }

        return {
          'x': px + dx * alpha,
          'y': py + dy * alpha,
          'z': face[pi]['z']!,
        };
      });
    });
  }

  String _categoryLabel(TryOnCategory cat) {
    switch (cat) {
      case TryOnCategory.lipstick:
        return 'Lipstick';
      case TryOnCategory.blush:
        return 'Blush';
      case TryOnCategory.eyeshadow:
        return 'Eyeshadow';
      case TryOnCategory.eyeliner:
        return 'Eyeliner';
      case TryOnCategory.foundation:
        return 'Foundation';
      case TryOnCategory.highlighter:
        return 'Highlighter';
    }
  }

  void _reset() {
    final lipShades =
        _allDbShades.where((s) => s.productKey.startsWith('lip_')).toList()
          ..sort((a, b) => a.shadeOrder.compareTo(b.shadeOrder));

    setState(() {
      _category = TryOnCategory.lipstick;
      _categoryShades.clear();
      _categoryIntensities.clear();
      if (lipShades.isNotEmpty) {
        _categoryShades[TryOnCategory.lipstick] = lipShades.first.color;
      }
      _categoryIntensities[TryOnCategory.lipstick] = 0.7;
    });
    _allShadesNotifier.value = _buildShadesMap();
    _allIntensitiesNotifier.value = _buildIntensitiesMap();
  }

  Future<void> _captureLook() async {
    if (_isSaving) return;
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return;

    // Snapshot face positions NOW before stream stops
    final currentFaces = List<List<Map<String, double>>>.from(
      _facesNotifier.value.map((f) => List<Map<String, double>>.from(f)),
    );
    final currentCategoryShades = Map<String, Color>.from(
      _allShadesNotifier.value,
    );
    final currentCategoryIntensities = Map<String, double>.from(
      _allIntensitiesNotifier.value,
    );

    setState(() => _isSaving = true);

    try {
      // 1. Stop stream and take camera photo
      if (camera.value.isStreamingImages) {
        await camera.stopImageStream();
      }
      final xFile = await camera.takePicture();
      final cameraBytes = await xFile.readAsBytes();

      // 2. Restart stream immediately
      await camera.startImageStream(_onCameraFrame);

      // 3. Load camera image
      final codec = await ui.instantiateImageCodec(cameraBytes);
      final frame = await codec.getNextFrame();
      final cameraUiImage = frame.image;

      final w = cameraUiImage.width.toDouble();
      final h = cameraUiImage.height.toDouble();

      // 4. Composite: draw camera photo + redraw MakeupPainter at exact camera size
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));

      // Draw camera photo (takePicture saves non-mirrored image)
      canvas.drawImage(cameraUiImage, Offset.zero, Paint());

      // Redraw makeup — front camera preview is mirrored but photo is not,
      // so we pass isFrontCamera: false to draw without mirror flip
      if (currentFaces.isNotEmpty) {
        final painter = MakeupPainter(
          faces: currentFaces,
          isFrontCamera: false,
          categoryShades: currentCategoryShades,
          categoryIntensities: currentCategoryIntensities,
        );
        painter.paint(canvas, Size(w, h));
      }

      final picture = recorder.endRecording();

      // 5. Downscale to 1280px max for smaller file size
      // Save at original camera resolution — no upscaling (would cause blur)
      final composited = await picture.toImage(w.round(), h.round());
      final pngData = await composited.toByteData(
        format: ui.ImageByteFormat.png,
      );
      final finalBytes = pngData!.buffer.asUint8List();

      // 6. Show premium name/tag dialog — user names the look before saving
      if (!mounted) return;
      setState(() => _isSaving = false); // re-enable UI while dialog is open

      // Build auto-suggested name
      final nameParts = <String>[];
      for (final entry in _categoryShades.entries) {
        final prefix = _prefixForCategory(entry.key);
        final catShades = _allDbShades
            .where((s) => s.productKey.startsWith(prefix))
            .toList();
        final match = catShades.firstWhere(
          (s) => s.color.value == entry.value.value,
          orElse: () =>
              catShades.isNotEmpty ? catShades.first : _allDbShades.first,
        );
        nameParts.add('${_categoryLabel(entry.key)} - ${match.shadeName}');
      }
      final suggestedName = nameParts.isNotEmpty
          ? nameParts.join(' + ')
          : _categoryLabel(_category);

      final result = await showDialog<Map<String, dynamic>>(
        context: context,
        barrierColor: Colors.black.withOpacity(0.6),
        builder: (_) => _SaveLookSheet(
          imageBytes: finalBytes,
          suggestedName: suggestedName,
        ),
      );

      if (result == null || !mounted) return; // user cancelled

      setState(() => _isSaving = true);

      final lookName = result['name'] as String;
      final selectedTags = result['tags'] as List<String>;

      // 7. Upload image to Supabase Storage
      final fileName = 'look_${DateTime.now().millisecondsSinceEpoch}.png';
      await Supabase.instance.client.storage
          .from('looks')
          .uploadBinary(
            fileName,
            finalBytes,
            fileOptions: const FileOptions(
              contentType: 'image/png',
              upsert: true,
            ),
          );

      final imageUrl = Supabase.instance.client.storage
          .from('looks')
          .getPublicUrl(fileName);

      // 8. Insert into saved_looks
      final insertedLook = await Supabase.instance.client
          .from('saved_looks')
          .insert({
            'look_name': lookName,
            'preview_image_url': imageUrl,
            'updated_at': DateTime.now().toIso8601String(),
            'tags': selectedTags,
          })
          .select('id')
          .single();

      final lookId = insertedLook['id'] as String;

      // 9. Insert saved_look_items for ALL active categories
      final itemRows = <Map<String, dynamic>>[];
      for (final entry in _categoryShades.entries) {
        final prefix = _prefixForCategory(entry.key);
        final catShades = _allDbShades
            .where((s) => s.productKey.startsWith(prefix))
            .toList();
        final match = catShades.firstWhere(
          (s) => s.color.value == entry.value.value,
          orElse: () =>
              catShades.isNotEmpty ? catShades.first : _allDbShades.first,
        );
        itemRows.add({
          'look_id': lookId,
          'product_key': match.productKey,
          'shade_key': match.shadeKey,
        });
      }
      if (itemRows.isNotEmpty) {
        await Supabase.instance.client
            .from('saved_look_items')
            .insert(itemRows);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.check_circle_outline, color: Colors.white, size: 18),
              SizedBox(width: 8),
              Text(
                'Look saved!',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          backgroundColor: Colors.black87,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      debugPrint('Capture error: $e');
      try {
        final cam = _camera;
        if (cam != null && !cam.value.isStreamingImages) {
          await cam.startImageStream(_onCameraFrame);
        }
      } catch (_) {}
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Could not save look. Please try again.'),
          backgroundColor: Colors.red.shade800,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _camera;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: _initializing
                  ? const Center(child: CircularProgressIndicator())
                  : _cameraError ||
                        controller == null ||
                        !controller.value.isInitialized
                  ? _CameraErrorView(onRetry: _initCamera)
                  : Builder(
                      builder: (context) {
                        final previewSize = controller.value.previewSize!;
                        final screenSize = MediaQuery.of(context).size;

                        final previewAspect =
                            previewSize.height / previewSize.width;

                        double scale = screenSize.aspectRatio / previewAspect;
                        if (scale < 1) scale = 1 / scale;

                        return Center(
                          child: Transform.scale(
                            scale: scale,
                            child: AspectRatio(
                              aspectRatio: previewAspect,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  CameraPreview(controller),
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: Container(
                                        decoration: BoxDecoration(
                                          gradient: RadialGradient(
                                            center: Alignment.center,
                                            radius: 0.95,
                                            colors: [
                                              Colors.transparent,
                                              Colors.black.withOpacity(0.15),
                                              Colors.black.withOpacity(0.35),
                                            ],
                                            stops: const [0.6, 0.85, 1.0],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  IgnorePointer(
                                    child: RepaintBoundary(
                                      key: _makeupKey,
                                      child: ValueListenableBuilder(
                                        valueListenable: _facesNotifier,
                                        builder: (_, faces, __) =>
                                            ValueListenableBuilder(
                                              valueListenable:
                                                  _allShadesNotifier,
                                              builder: (_, allShades, __) =>
                                                  ValueListenableBuilder(
                                                    valueListenable:
                                                        _allIntensitiesNotifier,
                                                    builder:
                                                        (
                                                          _,
                                                          allIntensities,
                                                          __,
                                                        ) => CustomPaint(
                                                          painter: MakeupPainter(
                                                            faces: faces,
                                                            isFrontCamera:
                                                                _isFrontCamera,
                                                            categoryShades:
                                                                allShades,
                                                            categoryIntensities:
                                                                allIntensities,
                                                          ),
                                                        ),
                                                  ),
                                            ),
                                      ),
                                    ),
                                  ),

                                  // No face detected overlay
                                  ValueListenableBuilder(
                                    valueListenable: _facesNotifier,
                                    builder: (_, faces, __) =>
                                        AnimatedOpacity(
                                          opacity: faces.isEmpty ? 1.0 : 0.0,
                                          duration: const Duration(milliseconds: 400),
                                          child: IgnorePointer(
                                            child: Align(
                                              alignment: const Alignment(0, -0.35),
                                              child: Container(
                                                padding: const EdgeInsets.symmetric(
                                                  horizontal: 18,
                                                  vertical: 10,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: Colors.black.withOpacity(0.45),
                                                  borderRadius: BorderRadius.circular(30),
                                                  border: Border.all(
                                                    color: Colors.white.withOpacity(0.15),
                                                  ),
                                                ),
                                                child: Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    Icon(
                                                      Icons.face_retouching_off_outlined,
                                                      color: Colors.white.withOpacity(0.75),
                                                      size: 16,
                                                    ),
                                                    const SizedBox(width: 8),
                                                    Text(
                                                      'Point camera at your face',
                                                      style: TextStyle(
                                                        color: Colors.white.withOpacity(0.85),
                                                        fontSize: 13,
                                                        fontWeight: FontWeight.w500,
                                                        letterSpacing: 0.2,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                  ),
                                  // Positioned(
                                  //   top: 80,
                                  //   left: 12,
                                  //   child: Container(
                                  //     padding: const EdgeInsets.all(6),
                                  //     color: Colors.black54,
                                  //     child: Text(
                                  //       'faces=${_faces.length} pts=${_faces.isEmpty ? 0 : _faces.first.length}',
                                  //       style: const TextStyle(
                                  //         color: Colors.white,
                                  //       ),
                                  //     ),
                                  //   ),
                                  // ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),

            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: _TopBar(
                onReset: _reset,
                onBack: () => Navigator.maybePop(context),
                onSavedLooks: () => context.push('/saved-looks'),
              ),
            ),

            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _BottomPanel(
                category: _category,
                shades: _filteredDbShades,
                selectedShade: _selectedShade,
                intensity: _intensity,
                isLoadingShades: _isLoadingShades,
                shadesError: _shadesError,
                onCategoryChanged: (c) {
                  final prefix = _prefixForCategory(c);
                  final nextShades =
                      _allDbShades
                          .where((s) => s.productKey.startsWith(prefix))
                          .toList()
                        ..sort((a, b) => a.shadeOrder.compareTo(b.shadeOrder));

                  setState(() {
                    _category = c;
                    if (!_categoryShades.containsKey(c) &&
                        nextShades.isNotEmpty) {
                      _categoryShades[c] = nextShades.first.color;
                      _allShadesNotifier.value = _buildShadesMap();
                    }
                    // Set default intensity for new category if not set
                    if (!_categoryIntensities.containsKey(c)) {
                      _categoryIntensities[c] = 0.7;
                      _allIntensitiesNotifier.value = _buildIntensitiesMap();
                    }
                  });
                },
                onShadeTap: (shade) {
                  setState(() => _categoryShades[_category] = shade);
                  _allShadesNotifier.value = _buildShadesMap();
                },
                onIntensityChanged: (v) {
                  setState(() => _categoryIntensities[_category] = v);
                  _allIntensitiesNotifier.value = _buildIntensitiesMap();
                },
              ),
            ),

            Positioned(
              right: 8,
              top: MediaQuery.of(context).size.height * 0.32,
              child: Container(
                width: 44,
                height: 170,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.22),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '${(_intensity * 100).round()}%',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Expanded(
                      child: RotatedBox(
                        quarterTurns: -1,
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 9,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 15,
                            ),
                            activeTrackColor: Colors.white,
                            inactiveTrackColor: Colors.white30,
                            thumbColor: Colors.white,
                            overlayColor: Colors.white10,
                          ),
                          child: Slider(
                            value: _intensity,
                            onChanged: (v) {
                              setState(
                                () => _categoryIntensities[_category] = v,
                              );
                              _allIntensitiesNotifier.value =
                                  _buildIntensitiesMap();
                            },
                            min: 0,
                            max: 1,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                ),
              ),
            ),

            // Capture button — added LAST so it renders on top of bottom panel
            Positioned(
              left: 0,
              right: 0,
              bottom: 215,
              child: Center(
                child: _CaptureButton(onTap: _captureLook, isSaving: _isSaving),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum TryOnCategory {
  lipstick,
  blush,
  eyeshadow,
  eyeliner,
  foundation,
  highlighter,
}

class _TopBar extends StatelessWidget {
  final VoidCallback onReset;
  final VoidCallback onBack;
  final VoidCallback onSavedLooks;

  const _TopBar({
    required this.onReset,
    required this.onBack,
    required this.onSavedLooks,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _GlassCircleButton(icon: Icons.arrow_back_ios_new, onTap: onBack),

          const Spacer(),

          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white.withOpacity(0.10)),
                ),
                child: const Text(
                  'Try-On',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ),
          ),

          const Spacer(),

          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _GlassCircleButton(icon: Icons.refresh, onTap: onReset),
              const SizedBox(height: 10),
              _GlassCircleButton(
                icon: Icons.collections_bookmark_outlined,
                onTap: onSavedLooks,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

//BOTTOM PANEL
class _BottomPanel extends StatelessWidget {
  final TryOnCategory category;
  final List<DbShade> shades;
  final Color selectedShade;
  final double intensity;
  final bool isLoadingShades;
  final String? shadesError;

  final ValueChanged<TryOnCategory> onCategoryChanged;
  final ValueChanged<Color> onShadeTap;
  final ValueChanged<double> onIntensityChanged;

  const _BottomPanel({
    required this.category,
    required this.shades,
    required this.selectedShade,
    required this.intensity,
    required this.isLoadingShades,
    required this.shadesError,
    required this.onCategoryChanged,
    required this.onShadeTap,
    required this.onIntensityChanged,
  });

  String _categoryTitle(TryOnCategory category) {
    switch (category) {
      case TryOnCategory.lipstick:
        return 'Lipstick';
      case TryOnCategory.blush:
        return 'Blush';
      case TryOnCategory.eyeshadow:
        return 'Eyeshadow';
      case TryOnCategory.eyeliner:
        return 'Eyeliner';
      case TryOnCategory.foundation:
        return 'Foundation';
      case TryOnCategory.highlighter:
        return 'Highlighter';
    }
  }

  DbShade? _selectedDbShade() {
    for (final shade in shades) {
      if (shade.color.value == selectedShade.value) return shade;
    }
    return shades.isNotEmpty ? shades.first : null;
  }

  @override
  Widget build(BuildContext context) {
    final selectedDbShade = _selectedDbShade();

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.50),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(
              top: BorderSide(color: Colors.white.withOpacity(0.10), width: 1),
            ),
            boxShadow: const [
              BoxShadow(
                color: Colors.black45,
                blurRadius: 18,
                offset: Offset(0, -6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),

              const SizedBox(height: 14),

              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _categoryTitle(category),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.2,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          selectedDbShade?.shadeName ?? 'Select a shade',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (selectedDbShade != null)
                    Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: selectedDbShade.color,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.6),
                      ),
                    ),
                ],
              ),

              const SizedBox(height: 14),

              SizedBox(
                height: 38,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children:
                      [
                        _CatChip('Lipstick', TryOnCategory.lipstick),
                        _CatChip('Blush', TryOnCategory.blush),
                        _CatChip('Eyeshadow', TryOnCategory.eyeshadow),
                        _CatChip('Eyeliner', TryOnCategory.eyeliner),
                        _CatChip('Foundation', TryOnCategory.foundation),
                        _CatChip('Highlight', TryOnCategory.highlighter),
                      ].map((chip) {
                        final isSelected = category == chip.value;

                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: GestureDetector(
                            onTap: () => onCategoryChanged(chip.value),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? Colors.white
                                    : Colors.white.withOpacity(0.08),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: isSelected
                                      ? Colors.white
                                      : Colors.white.withOpacity(0.14),
                                  width: 1,
                                ),
                              ),
                              child: Text(
                                chip.label,
                                style: TextStyle(
                                  color: isSelected
                                      ? Colors.black
                                      : Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                ),
              ),

              const SizedBox(height: 16),

              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Shades',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.88),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),

              const SizedBox(height: 10),

              SizedBox(
                height: 74,
                child: isLoadingShades
                    ? const Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : shadesError != null
                    ? Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          shadesError ?? 'Shades failed to load',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      )
                    : shades.isEmpty
                    ? const Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'No shades found',
                          style: TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      )
                    : ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: shades.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 12),
                        itemBuilder: (context, i) {
                          final shade = shades[i];
                          final c = shade.color;
                          final selected = c.value == selectedShade.value;

                          return GestureDetector(
                            onTap: () => onShadeTap(c),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              width: 56,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  AnimatedContainer(
                                    duration: const Duration(milliseconds: 180),
                                    width: selected ? 50 : 44,
                                    height: selected ? 50 : 44,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: selected
                                            ? Colors.white
                                            : Colors.white24,
                                        width: selected ? 3 : 1,
                                      ),
                                      boxShadow: selected
                                          ? [
                                              BoxShadow(
                                                color: Colors.white.withOpacity(
                                                  0.15,
                                                ),
                                                blurRadius: 10,
                                                spreadRadius: 1,
                                              ),
                                            ]
                                          : null,
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(3),
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: c,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    shade.shadeName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: selected
                                          ? Colors.white
                                          : Colors.white60,
                                      fontSize: 10.5,
                                      fontWeight: selected
                                          ? FontWeight.w600
                                          : FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),

              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}

class _CatChip {
  final String label;
  final TryOnCategory value;
  _CatChip(this.label, this.value);
}

class _GlassCircleButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _GlassCircleButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Material(
          color: Colors.black.withOpacity(0.18),
          child: InkWell(
            onTap: onTap,
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withOpacity(0.10)),
              ),
              child: Icon(icon, color: Colors.white, size: 19),
            ),
          ),
        ),
      ),
    );
  }
}

// class _CircleIconButton extends StatelessWidget {
//   final IconData icon;
//   final VoidCallback onTap;
//   const _CircleIconButton({required this.icon, required this.onTap});

//   @override
//   Widget build(BuildContext context) {
//     return Material(
//       color: Colors.black.withOpacity(0.35),
//       shape: const CircleBorder(),
//       child: InkWell(
//         onTap: onTap,
//         customBorder: const CircleBorder(),
//         child: Padding(
//           padding: const EdgeInsets.all(10),
//           child: Icon(icon, color: Colors.white),
//         ),
//       ),
//     );
//   }
// }

class _CaptureButton extends StatelessWidget {
  final VoidCallback onTap;
  final bool isSaving;

  const _CaptureButton({required this.onTap, required this.isSaving});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isSaving ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 68,
        height: 68,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withOpacity(isSaving ? 0.6 : 1.0),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.4),
              blurRadius: 16,
              spreadRadius: 2,
              offset: const Offset(0, 3),
            ),
          ],
          border: Border.all(color: Colors.white.withOpacity(0.5), width: 3),
        ),
        child: isSaving
            ? const Padding(
                padding: EdgeInsets.all(20),
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.black54,
                ),
              )
            : const Icon(
                Icons.camera_alt_rounded,
                color: Colors.black87,
                size: 30,
              ),
      ),
    );
  }
}

class _CameraErrorView extends StatelessWidget {
  final VoidCallback onRetry;
  const _CameraErrorView({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off, color: Colors.white70, size: 46),
            const SizedBox(height: 12),
            const Text(
              'Camera not available',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Please allow camera permission and try again.',
              style: TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),
            ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// Premium Save Look Bottom Sheet
// ─────────────────────────────────────────────

const _kAvailableTags = [
  'casual',
  'daytime',
  'evening',
  'bridal',
  'party',
  'office',
  'glam',
  'natural',
  'bold',
  'soft',
  'editorial',
  'glow',
];

class _SaveLookSheet extends StatefulWidget {
  final Uint8List imageBytes;
  final String suggestedName;
  const _SaveLookSheet({required this.imageBytes, required this.suggestedName});

  @override
  State<_SaveLookSheet> createState() => _SaveLookSheetState();
}

class _SaveLookSheetState extends State<_SaveLookSheet>
    with SingleTickerProviderStateMixin {
  late final TextEditingController _nameCtrl;
  final Set<String> _selectedTags = {};
  bool _tagsOpen = false;
  late final AnimationController _anim;
  late final Animation<double> _fadeAnim;
  late final Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.suggestedName);
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fadeAnim = CurvedAnimation(parent: _anim, curve: Curves.easeOut);
    _scaleAnim = Tween<double>(
      begin: 0.92,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic));
    _anim.forward();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _anim.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop({'name': name, 'tags': _selectedTags.toList()});
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnim,
      child: ScaleTransition(
        scale: _scaleAnim,
        child: Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 20),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: Colors.white.withOpacity(0.15)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.4),
                      blurRadius: 40,
                      spreadRadius: 0,
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header row — image + title
                      Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.memory(
                              widget.imageBytes,
                              width: 52,
                              height: 64,
                              fit: BoxFit.cover,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Save Your Look',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 19,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.3,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  'Name it & add tags',
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.45),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Close X
                          GestureDetector(
                            onTap: () => Navigator.of(context).pop(),
                            child: Container(
                              width: 30,
                              height: 30,
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.1),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.close_rounded,
                                color: Colors.white.withOpacity(0.6),
                                size: 16,
                              ),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 22),

                      // Name label
                      Text(
                        'LOOK NAME',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.4),
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.4,
                        ),
                      ),
                      const SizedBox(height: 8),

                      // Name field
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.15),
                          ),
                        ),
                        child: TextField(
                          controller: _nameCtrl,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                          decoration: InputDecoration(
                            hintText: 'e.g. Date Night Look',
                            hintStyle: TextStyle(
                              color: Colors.white.withOpacity(0.25),
                              fontSize: 14,
                            ),
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 12,
                            ),
                            suffixIcon: ValueListenableBuilder(
                              valueListenable: _nameCtrl,
                              builder: (_, __, ___) => _nameCtrl.text.isNotEmpty
                                  ? IconButton(
                                      icon: Icon(
                                        Icons.close_rounded,
                                        color: Colors.white.withOpacity(0.3),
                                        size: 16,
                                      ),
                                      onPressed: () => _nameCtrl.clear(),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ),
                          textCapitalization: TextCapitalization.words,
                          onSubmitted: (_) => FocusScope.of(context).unfocus(),
                        ),
                      ),

                      const SizedBox(height: 18),

                      // Tags label
                      Text(
                        'TAGS  (optional)',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.4),
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.4,
                        ),
                      ),
                      const SizedBox(height: 8),

                      // Tags dropdown button
                      GestureDetector(
                        onTap: () => setState(() => _tagsOpen = !_tagsOpen),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.15),
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: _selectedTags.isEmpty
                                    ? Text(
                                        'Select tags...',
                                        style: TextStyle(
                                          color: Colors.white.withOpacity(0.3),
                                          fontSize: 14,
                                        ),
                                      )
                                    : Wrap(
                                        spacing: 6,
                                        runSpacing: 4,
                                        children: _selectedTags
                                            .map(
                                              (t) => Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                      vertical: 3,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: Colors.white
                                                      .withOpacity(0.9),
                                                  borderRadius:
                                                      BorderRadius.circular(20),
                                                ),
                                                child: Text(
                                                  '#$t',
                                                  style: const TextStyle(
                                                    color: Colors.black,
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                              ),
                                            )
                                            .toList(),
                                      ),
                              ),
                              AnimatedRotation(
                                turns: _tagsOpen ? 0.5 : 0,
                                duration: const Duration(milliseconds: 200),
                                child: Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  color: Colors.white.withOpacity(0.5),
                                  size: 20,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // Dropdown list
                      AnimatedCrossFade(
                        duration: const Duration(milliseconds: 200),
                        crossFadeState: _tagsOpen
                            ? CrossFadeState.showSecond
                            : CrossFadeState.showFirst,
                        firstChild: const SizedBox.shrink(),
                        secondChild: Container(
                          margin: const EdgeInsets.only(top: 6),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.06),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.12),
                            ),
                          ),
                          // Fixed height so it never overflows — scrollable inside
                          constraints: const BoxConstraints(maxHeight: 200),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: _kAvailableTags.map((tag) {
                                  final sel = _selectedTags.contains(tag);
                                  return GestureDetector(
                                    onTap: () => setState(
                                      () => sel
                                          ? _selectedTags.remove(tag)
                                          : _selectedTags.add(tag),
                                    ),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 10,
                                      ),
                                      child: Row(
                                        children: [
                                          AnimatedContainer(
                                            duration: const Duration(
                                              milliseconds: 150,
                                            ),
                                            width: 18,
                                            height: 18,
                                            decoration: BoxDecoration(
                                              color: sel
                                                  ? Colors.white
                                                  : Colors.transparent,
                                              borderRadius:
                                                  BorderRadius.circular(5),
                                              border: Border.all(
                                                color: sel
                                                    ? Colors.white
                                                    : Colors.white
                                                        .withOpacity(0.3),
                                                width: 1.5,
                                              ),
                                            ),
                                            child: sel
                                                ? const Icon(
                                                    Icons.check_rounded,
                                                    color: Colors.black,
                                                    size: 12,
                                                  )
                                                : null,
                                          ),
                                          const SizedBox(width: 12),
                                          Text(
                                            '#$tag',
                                            style: TextStyle(
                                              color: sel
                                                  ? Colors.white
                                                  : Colors.white
                                                      .withOpacity(0.65),
                                              fontSize: 13.5,
                                              fontWeight: sel
                                                  ? FontWeight.w600
                                                  : FontWeight.w400,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 22),

                      // Buttons
                      Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: () => Navigator.of(context).pop(),
                              child: Container(
                                height: 48,
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.07),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: Colors.white.withOpacity(0.12),
                                  ),
                                ),
                                child: Center(
                                  child: Text(
                                    'Cancel',
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.6),
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 2,
                            child: GestureDetector(
                              onTap: _save,
                              child: Container(
                                height: 48,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(14),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.white.withOpacity(0.2),
                                      blurRadius: 16,
                                    ),
                                  ],
                                ),
                                child: const Center(
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.bookmark_rounded,
                                        color: Colors.black,
                                        size: 16,
                                      ),
                                      SizedBox(width: 7),
                                      Text(
                                        'Save Look',
                                        style: TextStyle(
                                          color: Colors.black,
                                          fontSize: 14,
                                          fontWeight: FontWeight.w700,
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
        ),
      ),
    );
  }
}