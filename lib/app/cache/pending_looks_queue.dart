import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class PendingLooksQueue {
  PendingLooksQueue._();
  static final PendingLooksQueue instance = PendingLooksQueue._();

  static const _manifestFileName = 'pending_saved_looks.json';
  static const _queueFolder = 'pending_saved_looks';

  List<Map<String, dynamic>> _pending = [];
  bool _loaded = false;

  List<Map<String, dynamic>> get pending => List.unmodifiable(_pending);

  Future<Directory> get _storageDirectory async {
    final baseDir = await getApplicationSupportDirectory();
    final dir = Directory('${baseDir.path}/$_queueFolder');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> get _manifestFile async {
    final dir = await _storageDirectory;
    return File('${dir.path}/$_manifestFileName');
  }

  Future<void> load() async {
    if (_loaded) return;
    try {
      final manifest = await _manifestFile;
      if (!await manifest.exists()) {
        _pending = [];
        _loaded = true;
        return;
      }

      final contents = await manifest.readAsString();
      if (contents.isEmpty) {
        _pending = [];
        _loaded = true;
        return;
      }

      final decoded = jsonDecode(contents) as List<dynamic>;
      _pending = decoded
          .map((item) => Map<String, dynamic>.from(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      _pending = [];
    } finally {
      _loaded = true;
    }
  }

  Future<void> _saveManifest() async {
    try {
      final manifest = await _manifestFile;
      await manifest.writeAsString(jsonEncode(_pending), flush: true);
    } catch (_) {
      // ignore write failures; retries will attempt again later
    }
  }

  Future<void> add(Map<String, dynamic> pendingLook, File previewImage) async {
    await load();
    final storageDir = await _storageDirectory;
    final fileName = 'pending_${pendingLook['id']}.jpg';
    final destFile = File('${storageDir.path}/$fileName');
    await previewImage.copy(destFile.path);
    pendingLook['preview_image_path'] = destFile.path;
    _pending.insert(0, pendingLook);
    await _saveManifest();
  }

  Future<void> remove(String id) async {
    await load();
    final idx = _pending.indexWhere((item) => item['id'] == id);
    if (idx == -1) return;
    final item = _pending[idx];
    final previewPath = item['preview_image_path'] as String?;
    if (previewPath != null) {
      try {
        final file = File(previewPath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }
    _pending.removeAt(idx);
    await _saveManifest();
  }

  Future<void> clear() async {
    await load();
    _pending.clear();
    await _saveManifest();
  }
}
