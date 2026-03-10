import 'package:flutter/services.dart';

class FaceMeshBridge {
  static const _channel = MethodChannel('makeup_tryon/face_mesh');

  static Future<List<List<Map<String, double>>>> detect({
    required Uint8List bytes,
    required int width,
    required int height,
    required int rotationDegrees,
  }) async {
    final res = await _channel.invokeMethod<Map>('detect', {
      'bytes': bytes,
      'width': width,
      'height': height,
      'rotationDegrees': rotationDegrees,
    });

    if (res == null) return [];

    final faces = res['faces'] as List;
    return faces.map<List<Map<String, double>>>((f) {
      return (f as List).map<Map<String, double>>((p) {
        return {
          'x': (p['x'] as num).toDouble(),
          'y': (p['y'] as num).toDouble(),
        };
      }).toList();
    }).toList();
  }
}
