package com.example.makeup_tryon

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.framework.image.MPImage
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.ImageProcessingOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.facelandmarker.FaceLandmarker
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

class FaceMeshRunner(context: Context) {

    private val landmarker: FaceLandmarker

    private fun fileToDirectByteBuffer(file: java.io.File): ByteBuffer {
        val bytes = file.readBytes()
        val buffer = ByteBuffer.allocateDirect(bytes.size).order(java.nio.ByteOrder.nativeOrder())
        buffer.put(bytes)
        buffer.rewind()
        return buffer
    }

    init {

        // 🔍 sanity check
        val models = context.assets.list("models")
        android.util.Log.d("ASSET_TEST", "models = ${models?.toList()}")

        // ✅ asset → internal storage
        val modelFile =
                copyAssetToFile(
                        context = context,
                        assetPath = "models/face_landmarker.task",
                        outFileName = "face_landmarker.task"
                )

        // ✅ file → ByteBuffer
        val modelBuffer = fileToDirectByteBuffer(modelFile)

        val baseOptions = BaseOptions.builder().setModelAssetBuffer(modelBuffer).build()

        val options =
                FaceLandmarker.FaceLandmarkerOptions.builder()
                        .setBaseOptions(baseOptions)
                        .setRunningMode(RunningMode.VIDEO)
                        .setNumFaces(1)
                        .build()

        landmarker = FaceLandmarker.createFromOptions(context, options)
    }

    private fun copyAssetToFile(
            context: Context,
            assetPath: String,
            outFileName: String
    ): java.io.File {
        val outFile = java.io.File(context.filesDir, outFileName)
        if (outFile.exists() && outFile.length() > 0) return outFile

        context.assets.open(assetPath).use { input ->
            java.io.FileOutputStream(outFile).use { output -> input.copyTo(output) }
        }
        return outFile
    }

    /** bytes MUST be NV21 (from Flutter conversion) */
    fun detectNv21(
            bytes: ByteArray,
            width: Int,
            height: Int,
            rotationDegrees: Int
    ): Map<String, Any> {

        val expected = width * height * 3 / 2
        android.util.Log.d(
                "NV21_CHECK",
                "len=${bytes.size} expected=$expected w=$width h=$height rot=$rotationDegrees"
        )

        if (bytes.size != expected) {
            android.util.Log.e("NV21_CHECK", "NOT NV21! returning empty")
            return mapOf("faces" to emptyList<Any>())
        }

        // NV21 → Bitmap (MediaPipe compatible)
        val bitmap = nv21ToBitmap(bytes, width, height)

        // Bitmap → MPImage
        val mpImage: MPImage = BitmapImageBuilder(bitmap).build()

        // val imageOptions =
        val imageOptions =
                ImageProcessingOptions.builder()
                        .setRotationDegrees(rotationDegrees) // ✅ no fixedRot
                        .build()

        android.util.Log.d("MP_ROT", "rot=$rotationDegrees (no-fix)")

        /// val result: FaceLandmarkerResult = landmarker.detect(mpImage, imageOptions)

        val result =
                landmarker.detectForVideo(
                        mpImage,
                        imageOptions,
                        android.os.SystemClock.uptimeMillis()
                )

        android.util.Log.d("MP_RESULT", "faces=${result.faceLandmarks().size}")

        val faces = mutableListOf<List<Map<String, Float>>>()

        for (face in result.faceLandmarks()) {
            val points = face.map { mapOf("x" to it.x(), "y" to it.y(), "z" to it.z()) }
            faces.add(points)
        }

        return mapOf("faces" to faces)
    }

    private fun nv21ToBitmap(nv21: ByteArray, width: Int, height: Int): Bitmap {
        val yuvImage = YuvImage(nv21, ImageFormat.NV21, width, height, null)
        val out = ByteArrayOutputStream()
        yuvImage.compressToJpeg(Rect(0, 0, width, height), 70, out)
        val imageBytes = out.toByteArray()
        return BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
    }
}
