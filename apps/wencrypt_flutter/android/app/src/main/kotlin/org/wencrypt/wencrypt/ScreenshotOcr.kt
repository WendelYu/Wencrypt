package org.wencrypt.wencrypt

import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.nio.ByteBuffer
import java.util.concurrent.Executors

object ScreenshotOcr {
    private const val MAX_IMAGE_BYTES = 16 * 1024 * 1024
    private const val MAX_IMAGE_DIMENSION = 1920
    private const val PREVIEW_MAX_DIMENSION = 1280

    private val executor = Executors.newSingleThreadExecutor()

    private val recognizer by lazy {
        TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
    }

    fun warmUp() {
        executor.execute {
            recognizer
        }
    }

    fun readBoundedStream(input: InputStream): ByteArray? {
        input.use { stream ->
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(16 * 1024)
            var total = 0
            while (true) {
                val read = stream.read(buffer)
                if (read <= 0) break
                total += read
                if (total > MAX_IMAGE_BYTES) return null
                out.write(buffer, 0, read)
            }
            val result = out.toByteArray()
            return if (result.isEmpty()) null else result
        }
    }

    fun readClipboardImage(context: Context): ByteArray? {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            ?: return null
        val clip = clipboard.primaryClip ?: return null
        val resolver = context.contentResolver
        val hasImageMime = clip.description.hasMimeType("image/*")
        for (i in 0 until clip.itemCount) {
            val uri = clip.getItemAt(i).uri ?: continue
            val mime = runCatching { resolver.getType(uri) }.getOrNull()
            if (!hasImageMime && (mime == null || !mime.startsWith("image/"))) continue
            val bytes = runCatching {
                resolver.openInputStream(uri)?.let { readBoundedStream(it) }
            }.getOrNull()
            if (bytes != null) return bytes
        }
        return null
    }

    private fun decodeScaledBitmap(bytes: ByteArray): Bitmap {
        val source = ImageDecoder.createSource(ByteBuffer.wrap(bytes))
        return ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            val width = info.size.width
            val height = info.size.height
            if (width > MAX_IMAGE_DIMENSION || height > MAX_IMAGE_DIMENSION) {
                val scale = MAX_IMAGE_DIMENSION.toFloat() / maxOf(width, height).toFloat()
                decoder.setTargetSize(
                    maxOf(1, (width * scale).toInt()),
                    maxOf(1, (height * scale).toInt()),
                )
            }
        }
    }

    private fun encodePreviewJpeg(bitmap: Bitmap): ByteArray {
        val maxDim = maxOf(bitmap.width, bitmap.height)
        val out = ByteArrayOutputStream()
        if (maxDim > PREVIEW_MAX_DIMENSION) {
            val scale = PREVIEW_MAX_DIMENSION.toFloat() / maxDim.toFloat()
            val targetW = maxOf(1, (bitmap.width * scale).toInt())
            val targetH = maxOf(1, (bitmap.height * scale).toInt())
            val scaled = Bitmap.createScaledBitmap(bitmap, targetW, targetH, true)
            try {
                scaled.compress(Bitmap.CompressFormat.JPEG, 85, out)
            } finally {
                if (scaled !== bitmap) scaled.recycle()
            }
        } else {
            bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)
        }
        return out.toByteArray()
    }

    private fun processBitmap(
        bitmap: Bitmap,
        previewBytes: ByteArray?,
        onSuccess: (Map<String, Any>) -> Unit,
        onError: (String) -> Unit,
    ) {
        val imageWidth = bitmap.width.toDouble()
        val imageHeight = bitmap.height.toDouble()
        if (imageWidth <= 0 || imageHeight <= 0) {
            bitmap.recycle()
            onError("invalid_image")
            return
        }

        val image = InputImage.fromBitmap(bitmap, 0)
        recognizer.process(image)
            .addOnSuccessListener { visionText ->
                val rawBlocks = mutableListOf<Map<String, Any>>()
                for (block in visionText.textBlocks) {
                    for (line in block.lines) {
                        val text = line.text.trim()
                        if (text.isEmpty()) continue
                        val box = line.boundingBox
                        val x = if (box != null) (box.left / imageWidth).coerceIn(0.0, 1.0) else 0.0
                        val y = if (box != null) (box.top / imageHeight).coerceIn(0.0, 1.0) else 0.0
                        val w = if (box != null) (box.width() / imageWidth).coerceIn(0.0, 1.0 - x) else 0.0
                        val h = if (box != null) (box.height() / imageHeight).coerceIn(0.0, 1.0 - y) else 0.0
                        rawBlocks.add(
                            mapOf(
                                "text" to text,
                                "x" to x,
                                "y" to y,
                                "w" to w,
                                "h" to h,
                            )
                        )
                    }
                }
                rawBlocks.sortWith(
                    compareBy<Map<String, Any>>(
                        { (it["y"] as Double) },
                        { (it["x"] as Double) },
                    )
                )
                val fullText = rawBlocks.joinToString("\n") { it["text"] as String }
                bitmap.recycle()
                val payload = mutableMapOf<String, Any>(
                    "text" to fullText,
                    "blocks" to rawBlocks,
                )
                if (previewBytes != null) {
                    payload["hasImage"] = true
                    payload["image"] = previewBytes
                }
                onSuccess(payload)
            }
            .addOnFailureListener {
                bitmap.recycle()
                onError("ocr_failed")
            }
    }

    fun recognizeImage(
        bytes: ByteArray,
        onSuccess: (Map<String, Any>) -> Unit,
        onError: (String) -> Unit,
    ) {
        if (bytes.isEmpty() || bytes.size > MAX_IMAGE_BYTES) {
            bytes.fill(0)
            onError("invalid_image")
            return
        }
        executor.execute {
            val bitmap = try {
                decodeScaledBitmap(bytes)
            } catch (_: Exception) {
                bytes.fill(0)
                onError("invalid_image")
                return@execute
            } finally {
                bytes.fill(0)
            }
            processBitmap(bitmap, previewBytes = null, onSuccess = onSuccess, onError = onError)
        }
    }

    fun readAndRecognizeClipboardImage(
        context: Context,
        onEmpty: () -> Unit,
        onSuccess: (Map<String, Any>) -> Unit,
        onError: (String) -> Unit,
    ) {
        executor.execute {
            val rawBytes = readClipboardImage(context)
            if (rawBytes == null || rawBytes.isEmpty()) {
                onEmpty()
                return@execute
            }
            val bitmap = try {
                decodeScaledBitmap(rawBytes)
            } catch (_: Exception) {
                rawBytes.fill(0)
                onError("invalid_image")
                return@execute
            } finally {
                rawBytes.fill(0)
            }
            val preview = try {
                encodePreviewJpeg(bitmap)
            } catch (_: Exception) {
                bitmap.recycle()
                onError("invalid_image")
                return@execute
            }
            if (preview.isEmpty()) {
                bitmap.recycle()
                onError("invalid_image")
                return@execute
            }
            processBitmap(bitmap, previewBytes = preview, onSuccess = onSuccess, onError = onError)
        }
    }
}
