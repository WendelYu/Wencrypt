package org.wencrypt.wencrypt

import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer

class QrDecoderTest {
    @Test
    fun validatesWencryptInvitesAndRejectsUnrelatedText() {
        assertTrue(QrDecoder.isWencryptInvite("wencrypt://join?v=2&p=abc123"))
        assertTrue(QrDecoder.isWencryptInvite("  WENCRYPT://join?v=2&lan=xyz  "))
        assertTrue(QrDecoder.isWencryptInvite("wencrypt://join?folder=work&vault=0123456789abcdef"))
        assertTrue(QrDecoder.isWencryptInvite("wencrypt-invite:v2:abc123"))

        assertFalse(QrDecoder.isWencryptInvite(""))
        assertFalse(QrDecoder.isWencryptInvite("wencrypt://join?"))
        assertFalse(QrDecoder.isWencryptInvite("wencrypt-invite:v2:"))
        assertFalse(QrDecoder.isWencryptInvite("https://example.com/login"))
        assertFalse(QrDecoder.isWencryptInvite("plain text"))
    }

    @Test
    fun extractsStridedYPlaneWithShortFinalRowAndDecodesDenseQr() {
        val lanUri = "wencrypt://join?v=2&lan=" + "A".repeat(156)
        val offlineUri = "wencrypt://join?v=2&p=" + "B".repeat(520)

        for (payload in listOf(lanUri, offlineUri)) {
            val width = 720
            val height = 600
            val rowStride = 768
            val yPlane = renderQrInFrame(payload, width = width, height = height)
            // Camera2 Y planes commonly omit trailing stride padding on the last row.
            val capacity = rowStride * (height - 1) + width
            val buf = ByteBuffer.allocateDirect(capacity)
            for (row in 0 until height) {
                buf.position(row * rowStride)
                buf.put(yPlane, row * width, width)
            }
            buf.rewind()

            val extracted = QrDecoder.extractYPlane(
                buffer = buf,
                rowStride = rowStride,
                pixelStride = 1,
                width = width,
                height = height,
            )
            assertEquals(payload, QrDecoder.decodeLuminance(extracted, width, height, centerCrop = false))
            assertEquals(payload, QrDecoder.decodeLuminance(extracted, width, height, centerCrop = true))
        }
    }

    @Test
    fun extractsNonUnitPixelStrideYPlane() {
        val uri = "wencrypt://join?v=2&lan=" + "C".repeat(120)
        val width = 480
        val height = 480
        val pixelStride = 2
        val rowStride = width * pixelStride + 16
        val yPlane = renderQrInFrame(uri, width = width, height = height)

        val buf = ByteBuffer.allocateDirect(rowStride * (height - 1) + width * pixelStride)
        for (row in 0 until height) {
            for (col in 0 until width) {
                buf.put(row * rowStride + col * pixelStride, yPlane[row * width + col])
            }
        }

        val extracted = QrDecoder.extractYPlane(
            buffer = buf,
            rowStride = rowStride,
            pixelStride = pixelStride,
            width = width,
            height = height,
        )
        assertEquals(uri, QrDecoder.decodeLuminance(extracted, width, height, centerCrop = false))
    }

    private fun renderQrInFrame(payload: String, width: Int, height: Int): ByteArray {
        val hints = mapOf(
            EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.L,
            EncodeHintType.CHARACTER_SET to "UTF-8",
            EncodeHintType.MARGIN to 4,
        )
        val matrix = QRCodeWriter().encode(payload, BarcodeFormat.QR_CODE, 0, 0, hints)
        val scale = minOf((width - 80) / matrix.width, (height - 80) / matrix.height).coerceIn(1, 3)
        val qrW = matrix.width * scale
        val qrH = matrix.height * scale
        val startX = (width - qrW) / 2
        val startY = (height - qrH) / 2

        val frame = ByteArray(width * height) { 235.toByte() }
        for (my in 0 until matrix.height) {
            for (mx in 0 until matrix.width) {
                if (!matrix[mx, my]) continue
                val baseY = startY + my * scale
                val baseX = startX + mx * scale
                for (dy in 0 until scale) {
                    val rowOffset = (baseY + dy) * width + baseX
                    for (dx in 0 until scale) {
                        frame[rowOffset + dx] = 16.toByte()
                    }
                }
            }
        }
        return frame
    }
}
