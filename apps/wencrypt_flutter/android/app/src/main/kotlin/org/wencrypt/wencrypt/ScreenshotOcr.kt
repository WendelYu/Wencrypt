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

object ScreenshotOcr {
    private const val MAX_IMAGE_BYTES = 16 * 1024 * 1024
    private const val MAX_IMAGE_DIMENSION = 4096

    private val recognizer by lazy {
        TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
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
        Thread {
            var bitmap: Bitmap? = null
            try {
                val source = ImageDecoder.createSource(ByteBuffer.wrap(bytes))
                val decoded = ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
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
                bitmap = decoded
            } catch (_: Exception) {
                bytes.fill(0)
                onError("invalid_image")
                return@Thread
            } finally {
                bytes.fill(0)
            }

            val imageWidth = bitmap.width.toDouble()
            val imageHeight = bitmap.height.toDouble()
            if (imageWidth <= 0 || imageHeight <= 0) {
                bitmap.recycle()
                onError("invalid_image")
                return@Thread
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
                    onSuccess(mapOf("text" to fullText, "blocks" to rawBlocks))
                }
                .addOnFailureListener {
                    bitmap.recycle()
                    onError("ocr_failed")
                }
        }.start()
    }
}
