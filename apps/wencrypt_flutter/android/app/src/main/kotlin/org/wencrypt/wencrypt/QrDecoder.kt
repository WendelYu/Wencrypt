package org.wencrypt.wencrypt

import android.graphics.Bitmap
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.LuminanceSource
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.ReaderException
import com.google.zxing.common.GlobalHistogramBinarizer
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import java.nio.ByteBuffer

object QrDecoder {
    private val decodeHints: Map<DecodeHintType, Any> = mapOf(
        DecodeHintType.TRY_HARDER to true,
        DecodeHintType.CHARACTER_SET to "UTF-8",
    )

    fun isWencryptInvite(raw: String): Boolean {
        val trimmed = raw.trim()
        return (trimmed.startsWith("wencrypt://join?", ignoreCase = true) &&
            trimmed.length > "wencrypt://join?".length) ||
            (trimmed.startsWith("wencrypt-invite:v2:", ignoreCase = true) &&
                trimmed.length > "wencrypt-invite:v2:".length)
    }

    fun extractYPlane(
        buffer: ByteBuffer,
        rowStride: Int,
        pixelStride: Int,
        width: Int,
        height: Int,
        reuse: ByteArray? = null,
    ): ByteArray {
        val total = width * height
        val out = if (reuse != null && reuse.size >= total) reuse else ByteArray(total)
        if (width <= 0 || height <= 0) return out
        val src = buffer.duplicate()
        if (pixelStride == 1 && rowStride == width) {
            src.position(0)
            src.get(out, 0, total)
        } else if (pixelStride == 1) {
            for (row in 0 until height) {
                src.position(row * rowStride)
                src.get(out, row * width, width)
            }
        } else {
            for (row in 0 until height) {
                val rowOffset = row * rowStride
                val outOffset = row * width
                for (col in 0 until width) {
                    out[outOffset + col] = src.get(rowOffset + col * pixelStride)
                }
            }
        }
        return out
    }

    fun decodeLuminance(
        yBytes: ByteArray,
        width: Int,
        height: Int,
        centerCrop: Boolean = false,
        tryInverted: Boolean = false,
    ): String? {
        if (width <= 0 || height <= 0 || yBytes.size < width * height) return null
        val left: Int
        val top: Int
        val cropW: Int
        val cropH: Int
        if (centerCrop) {
            val side = (minOf(width, height) * 0.78f).toInt().coerceAtLeast(1)
            left = ((width - side) / 2).coerceAtLeast(0)
            top = ((height - side) / 2).coerceAtLeast(0)
            cropW = minOf(side, width - left)
            cropH = minOf(side, height - top)
        } else {
            left = 0
            top = 0
            cropW = width
            cropH = height
        }
        val source = PlanarYUVLuminanceSource(
            yBytes,
            width,
            height,
            left,
            top,
            cropW,
            cropH,
            false,
        )
        return decodeSource(source, tryInverted)
    }

    fun decodeBitmap(bitmap: Bitmap): String? {
        decodeSingleBitmap(bitmap)?.let { return it }
        val maxDim = maxOf(bitmap.width, bitmap.height)
        if (maxDim > 900) {
            val scale = 900f / maxDim
            val scaledW = (bitmap.width * scale).toInt().coerceAtLeast(1)
            val scaledH = (bitmap.height * scale).toInt().coerceAtLeast(1)
            val scaled = Bitmap.createScaledBitmap(bitmap, scaledW, scaledH, true)
            try {
                return decodeSingleBitmap(scaled)
            } finally {
                if (scaled !== bitmap && !scaled.isRecycled) {
                    scaled.recycle()
                }
            }
        }
        return null
    }

    private fun decodeSingleBitmap(bitmap: Bitmap): String? {
        val w = bitmap.width
        val h = bitmap.height
        if (w <= 0 || h <= 0) return null
        val pixels = IntArray(w * h)
        bitmap.getPixels(pixels, 0, w, 0, 0, w, h)
        return decodeSource(RGBLuminanceSource(w, h, pixels), tryInverted = true)
    }

    private fun decodeSource(source: LuminanceSource, tryInverted: Boolean): String? {
        val reader = QRCodeReader()
        fun tryDecode(bitmap: BinaryBitmap): String? {
            return try {
                reader.decode(bitmap, decodeHints).text
            } catch (_: ReaderException) {
                null
            } finally {
                reader.reset()
            }
        }

        tryDecode(BinaryBitmap(HybridBinarizer(source)))?.let { return it }
        tryDecode(BinaryBitmap(GlobalHistogramBinarizer(source)))?.let { return it }
        if (tryInverted) {
            val inverted = source.invert()
            tryDecode(BinaryBitmap(HybridBinarizer(inverted)))?.let { return it }
            tryDecode(BinaryBitmap(GlobalHistogramBinarizer(inverted)))?.let { return it }
        }
        return null
    }
}
