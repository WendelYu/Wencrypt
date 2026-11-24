package org.wencrypt.wencrypt

import android.Manifest
import android.animation.ValueAnimator
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.provider.Settings
import android.util.Size
import android.util.TypedValue
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.animation.LinearInterpolator
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.fragment.app.FragmentActivity
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class QrScannerActivity : FragmentActivity() {
    companion object {
        const val EXTRA_QR_RESULT = "org.wencrypt.qr_result"
    }

    private lateinit var previewView: PreviewView
    private lateinit var overlayView: ScannerOverlayView
    private lateinit var topBar: LinearLayout
    private lateinit var bottomPanel: LinearLayout
    private lateinit var feedbackBanner: TextView
    private lateinit var torchButton: Button
    private lateinit var permissionCard: LinearLayout

    private lateinit var analysisExecutor: ExecutorService
    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var cameraBound = false
    private var torchEnabled = false

    private val delivered = AtomicBoolean(false)
    private var yBuffer: ByteArray? = null
    private var frameCount = 0L
    private var lastFeedbackAt = 0L

    private val requestCameraPermission = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted) {
            permissionCard.visibility = View.GONE
            startCamera()
        } else {
            showPermissionFallback()
        }
    }

    private val pickImageLauncher = registerForActivityResult(
        ActivityResultContracts.GetContent()
    ) { uri: Uri? ->
        if (uri != null) {
            decodeGalleryImage(uri)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            isAppearanceLightStatusBars = false
            isAppearanceLightNavigationBars = false
        }

        analysisExecutor = Executors.newSingleThreadExecutor()
        buildUi()

        if (hasCameraPermission()) {
            permissionCard.visibility = View.GONE
            startCamera()
        } else {
            requestCameraPermission.launch(Manifest.permission.CAMERA)
        }
    }

    override fun onResume() {
        super.onResume()
        if (permissionCard.visibility == View.GONE) {
            overlayView.startAnimationIfNeeded()
        }
        if (hasCameraPermission() && !cameraBound) {
            permissionCard.visibility = View.GONE
            startCamera()
        }
    }

    override fun onPause() {
        overlayView.pauseAnimation()
        super.onPause()
    }

    override fun onDestroy() {
        overlayView.stopAnimation()
        cameraProvider?.unbindAll()
        analysisExecutor.shutdown()
        super.onDestroy()
    }

    private fun hasCameraPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED

    private fun showPermissionFallback() {
        overlayView.pauseAnimation()
        permissionCard.visibility = View.VISIBLE
    }

    private fun buildUi() {
        val root = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
        }

        previewView = PreviewView(this).apply {
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }
        root.addView(
            previewView,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
        attachCameraGestures()

        overlayView = ScannerOverlayView(this)
        root.addView(
            overlayView,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )

        // Top bar
        topBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), dp(12), dp(16), dp(12))
        }
        val closeButton = Button(this).apply {
            text = "✕"
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            isAllCaps = false
            background = pillDrawable(Color.argb(140, 20, 24, 32), radiusDp = 20)
            minWidth = dp(40)
            minimumWidth = dp(40)
            minHeight = dp(40)
            minimumHeight = dp(40)
            setPadding(0, 0, 0, 0)
            contentDescription = "关闭扫码"
            setOnClickListener {
                setResult(RESULT_CANCELED)
                finish()
            }
        }
        val titleView = TextView(this).apply {
            text = "扫一扫加入"
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
            gravity = Gravity.CENTER
            setPadding(dp(12), 0, dp(40), 0)
        }
        topBar.addView(closeButton, LinearLayout.LayoutParams(dp(40), dp(40)))
        topBar.addView(
            titleView,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
        )
        root.addView(
            topBar,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.TOP,
            ),
        )

        // Permission fallback card (centered)
        permissionCard = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            visibility = View.GONE
            background = pillDrawable(Color.argb(232, 24, 28, 38), radiusDp = 16, strokeColor = Color.argb(80, 255, 255, 255))
            setPadding(dp(22), dp(22), dp(22), dp(22))
        }
        val permTitle = TextView(this).apply {
            text = "需要相机权限才能扫码加入"
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            gravity = Gravity.CENTER
        }
        val permBody = TextView(this).apply {
            text = "Wencrypt 仅在本地离线识别二维码，不上传任何画面。您也可以直接从相册选择二维码截图。"
            setTextColor(Color.argb(210, 226, 232, 240))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            gravity = Gravity.CENTER
            setPadding(0, dp(8), 0, dp(16))
        }
        val openSettingsBtn = pillActionButton(
            label = "打开系统设置",
            fill = Color.parseColor("#2563EB"),
        ) {
            val intent = Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", packageName, null),
            )
            startActivity(intent)
        }
        val pickFromCardBtn = pillActionButton(
            label = "从相册选择二维码",
            fill = Color.argb(180, 51, 65, 85),
        ) {
            pickImageLauncher.launch("image/*")
        }
        permissionCard.addView(permTitle)
        permissionCard.addView(permBody)
        permissionCard.addView(
            openSettingsBtn,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(42)).apply {
                bottomMargin = dp(10)
            },
        )
        permissionCard.addView(
            pickFromCardBtn,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(42)),
        )
        root.addView(
            permissionCard,
            FrameLayout.LayoutParams(
                dp(300),
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER,
            ),
        )

        // Bottom controls
        bottomPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(20), dp(12), dp(20), dp(24))
        }

        feedbackBanner = TextView(this).apply {
            visibility = View.GONE
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f)
            gravity = Gravity.CENTER
            background = pillDrawable(Color.argb(215, 185, 28, 28), radiusDp = 18)
            setPadding(dp(14), dp(8), dp(14), dp(8))
        }
        bottomPanel.addView(
            feedbackBanner,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { bottomMargin = dp(12) },
        )

        val hintText = TextView(this).apply {
            text = "对准另一台设备上的 Wencrypt 二维码（轻触对焦 / 双指缩放）"
            setTextColor(Color.argb(225, 241, 245, 249))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            gravity = Gravity.CENTER
        }
        bottomPanel.addView(
            hintText,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { bottomMargin = dp(16) },
        )

        val actionsRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        torchButton = pillActionButton(
            label = "打开手电筒",
            fill = Color.argb(155, 20, 24, 32),
        ) {
            val cam = camera ?: return@pillActionButton
            torchEnabled = !torchEnabled
            cam.cameraControl.enableTorch(torchEnabled)
            torchButton.text = if (torchEnabled) "关闭手电筒" else "打开手电筒"
        }.apply {
            visibility = View.GONE
        }
        val galleryButton = pillActionButton(
            label = "相册识别",
            fill = Color.argb(155, 20, 24, 32),
        ) {
            pickImageLauncher.launch("image/*")
        }
        actionsRow.addView(
            torchButton,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                dp(40),
            ).apply { marginEnd = dp(12) },
        )
        actionsRow.addView(
            galleryButton,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                dp(40),
            ),
        )
        bottomPanel.addView(actionsRow)

        root.addView(
            bottomPanel,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM,
            ),
        )

        ViewCompat.setOnApplyWindowInsetsListener(root) { _, insets ->
            val bars = insets.getInsets(
                WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout(),
            )
            topBar.setPadding(
                dp(16) + bars.left,
                dp(12) + bars.top,
                dp(16) + bars.right,
                dp(12),
            )
            bottomPanel.setPadding(
                dp(20) + bars.left,
                dp(12),
                dp(20) + bars.right,
                dp(24) + bars.bottom,
            )
            insets
        }

        setContentView(root)
    }

    private fun attachCameraGestures() {
        var isPinching = false
        val scaleDetector = ScaleGestureDetector(
            this,
            object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
                override fun onScaleBegin(detector: ScaleGestureDetector): Boolean {
                    isPinching = true
                    return true
                }

                override fun onScale(detector: ScaleGestureDetector): Boolean {
                    val cam = camera ?: return false
                    val zoom = cam.cameraInfo.zoomState.value ?: return false
                    val next = (zoom.zoomRatio * detector.scaleFactor)
                        .coerceIn(zoom.minZoomRatio, zoom.maxZoomRatio)
                    cam.cameraControl.setZoomRatio(next)
                    return true
                }
            },
        )
        previewView.setOnTouchListener { v, event ->
            scaleDetector.onTouchEvent(event)
            if (event.actionMasked == MotionEvent.ACTION_DOWN) {
                isPinching = false
            } else if (
                event.actionMasked == MotionEvent.ACTION_UP &&
                !isPinching &&
                !scaleDetector.isInProgress &&
                event.eventTime - event.downTime < 250L
            ) {
                val cam = camera
                if (cam != null) {
                    val point = previewView.meteringPointFactory.createPoint(event.x, event.y)
                    val action = FocusMeteringAction.Builder(
                        point,
                        FocusMeteringAction.FLAG_AF or FocusMeteringAction.FLAG_AE,
                    ).build()
                    cam.cameraControl.startFocusAndMetering(action)
                }
                v.performClick()
            }
            true
        }
    }

    private fun startCamera() {
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            if (isDestroyed || isFinishing) return@addListener
            try {
                val provider = future.get()
                cameraProvider = provider

                val selector = when {
                    provider.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA) ->
                        CameraSelector.DEFAULT_BACK_CAMERA
                    provider.hasCamera(CameraSelector.DEFAULT_FRONT_CAMERA) ->
                        CameraSelector.DEFAULT_FRONT_CAMERA
                    else -> {
                        showInlineFeedback("未检测到可用摄像头，请使用「相册识别」选择二维码图片。")
                        return@addListener
                    }
                }

                val preview = Preview.Builder().build().apply {
                    surfaceProvider = previewView.surfaceProvider
                }

                val resolutionSelector = ResolutionSelector.Builder()
                    .setAspectRatioStrategy(AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY)
                    .setResolutionStrategy(
                        ResolutionStrategy(
                            Size(1280, 960),
                            ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                        ),
                    )
                    .build()

                val analysis = ImageAnalysis.Builder()
                    .setResolutionSelector(resolutionSelector)
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()
                    .apply {
                        setAnalyzer(analysisExecutor) { proxy ->
                            analyzeFrame(proxy)
                        }
                    }

                provider.unbindAll()
                val bound = provider.bindToLifecycle(this, selector, preview, analysis)
                camera = bound
                cameraBound = true
                torchEnabled = false
                if (bound.cameraInfo.hasFlashUnit()) {
                    torchButton.visibility = View.VISIBLE
                    torchButton.text = "打开手电筒"
                } else {
                    torchButton.visibility = View.GONE
                }
                overlayView.startAnimationIfNeeded()
            } catch (_: Exception) {
                showInlineFeedback("无法启动相机预览，请尝试「相册识别」选择二维码图片。")
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun analyzeFrame(imageProxy: ImageProxy) {
        try {
            if (delivered.get()) return
            val plane = imageProxy.planes.firstOrNull() ?: return
            val w = imageProxy.width
            val h = imageProxy.height
            if (w <= 0 || h <= 0) return

            val buffer = QrDecoder.extractYPlane(
                buffer = plane.buffer,
                rowStride = plane.rowStride,
                pixelStride = plane.pixelStride,
                width = w,
                height = h,
                reuse = yBuffer,
            )
            yBuffer = buffer

            val step = frameCount++
            val centerCrop = (step % 2L == 0L)
            val tryInverted = (step % 4L == 3L)

            val decoded = QrDecoder.decodeLuminance(
                yBytes = buffer,
                width = w,
                height = h,
                centerCrop = centerCrop,
                tryInverted = tryInverted,
            )
            if (decoded != null) {
                handleDecodedText(decoded)
            }
        } finally {
            imageProxy.close()
        }
    }

    private fun decodeGalleryImage(uri: Uri) {
        analysisExecutor.execute {
            var bitmap: Bitmap? = null
            try {
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                contentResolver.openInputStream(uri)?.use { stream ->
                    BitmapFactory.decodeStream(stream, null, bounds)
                }
                if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
                    runOnUiThread { showInlineFeedback("无法读取所选图片，请重新选择。") }
                    return@execute
                }
                var sampleSize = 1
                val maxDim = maxOf(bounds.outWidth, bounds.outHeight)
                while (maxDim / sampleSize > 1600) {
                    sampleSize *= 2
                }
                val decodeOpts = BitmapFactory.Options().apply {
                    inSampleSize = sampleSize
                    inPreferredConfig = Bitmap.Config.ARGB_8888
                }
                bitmap = contentResolver.openInputStream(uri)?.use { stream ->
                    BitmapFactory.decodeStream(stream, null, decodeOpts)
                }
                val target = bitmap
                if (target == null) {
                    runOnUiThread { showInlineFeedback("无法解码所选图片，请重新选择。") }
                    return@execute
                }
                val decoded = QrDecoder.decodeBitmap(target)
                if (decoded == null) {
                    runOnUiThread { showInlineFeedback("未在图片中识别到有效的 Wencrypt 邀请二维码") }
                    return@execute
                }
                if (QrDecoder.isWencryptInvite(decoded)) {
                    deliverInvite(decoded.trim())
                } else {
                    runOnUiThread { showInlineFeedback("图片中的二维码不是 Wencrypt 邀请码，请选择另一张。") }
                }
            } catch (_: Exception) {
                runOnUiThread { showInlineFeedback("读取图片失败，请重试。") }
            } finally {
                bitmap?.let { if (!it.isRecycled) it.recycle() }
            }
        }
    }

    private fun handleDecodedText(raw: String) {
        if (QrDecoder.isWencryptInvite(raw)) {
            deliverInvite(raw.trim())
            return
        }
        val now = SystemClock.elapsedRealtime()
        if (now - lastFeedbackAt >= 1500L) {
            lastFeedbackAt = now
            runOnUiThread {
                showInlineFeedback("这不是 Wencrypt 邀请二维码，请扫描另一台设备上的 Wencrypt 二维码")
            }
        }
    }

    private fun deliverInvite(inviteUri: String) {
        if (!delivered.compareAndSet(false, true)) return
        runOnUiThread {
            val haptic = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                HapticFeedbackConstants.CONFIRM
            } else {
                HapticFeedbackConstants.VIRTUAL_KEY
            }
            previewView.performHapticFeedback(haptic)
            setResult(RESULT_OK, Intent().putExtra(EXTRA_QR_RESULT, inviteUri))
            finish()
        }
    }

    private fun showInlineFeedback(text: String) {
        feedbackBanner.text = text
        feedbackBanner.visibility = View.VISIBLE
    }

    private fun pillActionButton(
        label: String,
        fill: Int,
        onClick: () -> Unit,
    ): Button = Button(this).apply {
        text = label
        setTextColor(Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13.5f)
        isAllCaps = false
        background = pillDrawable(fill, radiusDp = 20, strokeColor = Color.argb(65, 255, 255, 255))
        setPadding(dp(18), 0, dp(18), 0)
        minHeight = dp(40)
        minimumHeight = dp(40)
        setOnClickListener { onClick() }
    }

    private fun pillDrawable(
        fillColor: Int,
        radiusDp: Int,
        strokeColor: Int = Color.TRANSPARENT,
    ): GradientDrawable = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        setColor(fillColor)
        cornerRadius = dpF(radiusDp)
        if (strokeColor != Color.TRANSPARENT) {
            setStroke(dp(1), strokeColor)
        }
    }

    private fun dp(value: Int): Int =
        TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            value.toFloat(),
            resources.displayMetrics,
        ).toInt()

    private fun dpF(value: Int): Float =
        TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            value.toFloat(),
            resources.displayMetrics,
        )

    private class ScannerOverlayView(context: Context) : View(context) {
        private val scrimPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(153, 0, 0, 0)
        }
        private val clearPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            xfermode = PorterDuffXfermode(PorterDuff.Mode.CLEAR)
        }
        private val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            color = Color.argb(90, 255, 255, 255)
            strokeWidth = dpF(1f)
        }
        private val cornerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            color = Color.parseColor("#3B82F6")
            strokeWidth = dpF(3.2f)
            strokeCap = Paint.Cap.ROUND
        }
        private val linePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL
            color = Color.argb(190, 59, 130, 246)
        }
        private val boxRect = RectF()
        private val lineRect = RectF()
        private var scanFraction = 0f

        private val scanAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 2100L
            repeatMode = ValueAnimator.REVERSE
            repeatCount = ValueAnimator.INFINITE
            interpolator = LinearInterpolator()
            addUpdateListener { anim ->
                scanFraction = anim.animatedValue as Float
                invalidate()
            }
        }

        fun startAnimationIfNeeded() {
            if (!scanAnimator.isStarted) {
                scanAnimator.start()
            } else if (scanAnimator.isPaused) {
                scanAnimator.resume()
            }
        }

        fun pauseAnimation() {
            if (scanAnimator.isRunning) {
                scanAnimator.pause()
            }
        }

        fun stopAnimation() {
            scanAnimator.cancel()
        }

        override fun onDetachedFromWindow() {
            scanAnimator.cancel()
            super.onDetachedFromWindow()
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val w = width.toFloat()
            val h = height.toFloat()
            if (w <= 0f || h <= 0f) return

            val boxSize = minOf(w * 0.68f, dpF(300f))
            val left = (w - boxSize) / 2f
            val top = (h - boxSize) / 2f - dpF(20f)
            boxRect.set(left, top, left + boxSize, top + boxSize)

            val cornerRadius = dpF(16f)
            val saved = canvas.saveLayer(0f, 0f, w, h, null)
            canvas.drawRect(0f, 0f, w, h, scrimPaint)
            canvas.drawRoundRect(boxRect, cornerRadius, cornerRadius, clearPaint)
            canvas.restoreToCount(saved)

            canvas.drawRoundRect(boxRect, cornerRadius, cornerRadius, borderPaint)

            // Scan line
            val pad = dpF(14f)
            val minY = boxRect.top + pad
            val maxY = boxRect.bottom - pad - dpF(2f)
            val y = minY + (maxY - minY) * scanFraction
            lineRect.set(boxRect.left + pad, y, boxRect.right - pad, y + dpF(2f))
            canvas.drawRoundRect(lineRect, dpF(1f), dpF(1f), linePaint)

            // Corner accents
            val arm = dpF(22f)
            val l = boxRect.left
            val t = boxRect.top
            val r = boxRect.right
            val b = boxRect.bottom
            canvas.drawLine(l, t + arm, l, t + dpF(4f), cornerPaint)
            canvas.drawLine(l + dpF(4f), t, l + arm, t, cornerPaint)

            canvas.drawLine(r - arm, t, r - dpF(4f), t, cornerPaint)
            canvas.drawLine(r, t + dpF(4f), r, t + arm, cornerPaint)

            canvas.drawLine(l, b - arm, l, b - dpF(4f), cornerPaint)
            canvas.drawLine(l + dpF(4f), b, l + arm, b, cornerPaint)

            canvas.drawLine(r - arm, b, r - dpF(4f), b, cornerPaint)
            canvas.drawLine(r, b - arm, r, b - dpF(4f), cornerPaint)
        }

        private fun dpF(value: Float): Float =
            TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP,
                value,
                resources.displayMetrics,
            )
    }
}
