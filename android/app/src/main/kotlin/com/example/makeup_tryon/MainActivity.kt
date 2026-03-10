package com.example.makeup_tryon

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "makeup_tryon/face_mesh"
    private var faceMeshRunner: FaceMeshRunner? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->

                when (call.method) {
                    "detect" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        val width = call.argument<Int>("width")
                        val height = call.argument<Int>("height")
                        val rotation = call.argument<Int>("rotationDegrees")

                        if (bytes == null || width == null || height == null || rotation == null) {
                            result.error("BAD_ARGS", "Missing detect args", null)
                            return@setMethodCallHandler
                        }

                        try {
                            // ✅ lazy init (only when first frame arrives)
                            val runner = faceMeshRunner ?: FaceMeshRunner(applicationContext).also {
                                faceMeshRunner = it
                            }

                            val output = runner.detectNv21(bytes, width, height, rotation)
                            result.success(output)

                        } catch (e: Throwable) {
                            // ✅ now it won't crash the app; you'll see the error in Flutter
                            result.error("FACE_MESH_INIT_OR_DETECT_ERROR", e.message, e.toString())
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }
}
