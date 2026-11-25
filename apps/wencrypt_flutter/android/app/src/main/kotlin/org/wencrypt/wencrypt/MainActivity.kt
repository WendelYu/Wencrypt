package org.wencrypt.wencrypt

import android.content.ContentValues
import android.content.Intent
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    companion object {
        private const val REQUEST_SAVE_BACKUP = 7401
        private const val REQUEST_QR_SCAN = 7402
    }

    private var backupResult: MethodChannel.Result? = null
    private var backupBytes: ByteArray? = null
    private var scanResult: MethodChannel.Result? = null
    private var inviteChannel: MethodChannel? = null
    private var pendingInvite: String? = null
    private var ocrChannel: MethodChannel? = null
    private val pendingImageLock = Any()
    private var pendingSharedImage: ByteArray? = null

    private fun receiveInvite(intent: Intent?) {
        val uri = intent?.data ?: return
        if (uri.scheme != "wencrypt" || uri.host != "join") return
        pendingInvite = uri.toString()
        inviteChannel?.invokeMethod("available", null)
    }

    private fun receiveSharedImage(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND) return
        val type = intent.type ?: ""
        if (type.isNotEmpty() && !type.startsWith("image/")) return
        val streamUri = if (android.os.Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, android.net.Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }
        val uri = streamUri ?: intent.clipData?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.uri ?: return
        val stream = runCatching { contentResolver.openInputStream(uri) }.getOrNull() ?: return
        Thread {
            val bytes = runCatching { ScreenshotOcr.readBoundedStream(stream) }.getOrNull() ?: return@Thread
            runOnUiThread {
                synchronized(pendingImageLock) {
                    pendingSharedImage?.fill(0)
                    pendingSharedImage = bytes
                }
                ocrChannel?.invokeMethod("sharedImageAvailable", null)
            }
        }.start()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        receiveInvite(intent)
        receiveSharedImage(intent)
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        receiveInvite(intent)
        receiveSharedImage(intent)
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
    }

    override fun onDestroy() {
        synchronized(pendingImageLock) {
            pendingSharedImage?.fill(0)
            pendingSharedImage = null
        }
        super.onDestroy()
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_QR_SCAN) {
            val result = scanResult
            scanResult = null
            if (resultCode == android.app.Activity.RESULT_OK) {
                result?.success(data?.getStringExtra(QrScannerActivity.EXTRA_QR_RESULT))
            } else {
                result?.success(null)
            }
            return
        }
        if (requestCode != REQUEST_SAVE_BACKUP) return
        val result = backupResult
        val bytes = backupBytes
        backupResult = null
        backupBytes = null
        try {
            if (resultCode == android.app.Activity.RESULT_OK && data?.data != null && bytes != null) {
                contentResolver.openOutputStream(data.data!!, "wt")!!.use { it.write(bytes) }
                result?.success(true)
            } else { result?.success(false) }
        } catch (_: Exception) { result?.error("save_failed", "Backup write failed", null) }
    }

    private val vaultDevice by lazy { DeviceVault(this) }
    override fun onStop() { vaultDevice.cancel(); super.onStop() }

    private fun saveEntryImage(bytes: ByteArray) {
        val images = MediaStore.Images.Media
            .getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "Wencrypt-${java.util.UUID.randomUUID()}.png")
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/Wencrypt")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val uri = checkNotNull(contentResolver.insert(images, values))
        try {
            checkNotNull(contentResolver.openOutputStream(uri)).use { it.write(bytes) }
            val published = ContentValues().apply {
                put(MediaStore.Images.Media.IS_PENDING, 0)
            }
            check(contentResolver.update(uri, published, null, null) == 1)
        } catch (error: Exception) {
            runCatching { contentResolver.delete(uri, null, null) }
            throw error
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ScreenshotOcr.warmUp()
        inviteChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.wencrypt.invite").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "takePending" -> {
                        val invitation = pendingInvite
                        pendingInvite = null
                        result.success(invitation)
                    }
                    "scanQr" -> {
                        if (scanResult != null) {
                            result.error("busy", "A QR scan is already in progress", null)
                            return@setMethodCallHandler
                        }
                        scanResult = result
                        try {
                            startActivityForResult(
                                Intent(this@MainActivity, QrScannerActivity::class.java),
                                REQUEST_QR_SCAN,
                            )
                        } catch (_: Exception) {
                            scanResult = null
                            result.error("scan_unavailable", "QR scanner unavailable", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.wencrypt.device/vault")
            .setMethodCallHandler { call, result ->
                @Suppress("UNCHECKED_CAST")
                vaultDevice.perform(call.method, call.arguments as? Map<String, Any?> ?: emptyMap()) { result.success(it) }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.wencrypt.files")
            .setMethodCallHandler { call, result ->
                if (call.method == "saveBackup") {
                    if (backupResult != null) { result.error("busy", "A save is pending", null); return@setMethodCallHandler }
                    backupBytes = call.argument<ByteArray>("bytes")
                    backupResult = result
                    try {
                        startActivityForResult(android.content.Intent(android.content.Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(android.content.Intent.CATEGORY_OPENABLE)
                            type = "application/octet-stream"
                            val name = when (call.argument<String>("name")) {
                                "wencrypt-recovery.wenrecover" -> "wencrypt-recovery.wenrecover"
                                else -> "wencrypt-backup.wenback"
                            }
                            putExtra(Intent.EXTRA_TITLE, name)
                        }, REQUEST_SAVE_BACKUP)
                    } catch (_: Exception) { backupBytes = null; backupResult = null; result.error("save_failed", "File picker unavailable", null) }
                } else if (call.method == "copySensitive") {
                    val text = call.argument<String>("text") ?: ""
                    val manager = getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
                    val clip = android.content.ClipData.newPlainText("Wencrypt", text)
                    if (android.os.Build.VERSION.SDK_INT >= 33) {
                        clip.description.extras = android.os.PersistableBundle().apply { putBoolean(android.content.ClipDescription.EXTRA_IS_SENSITIVE, true) }
                    }
                    manager.setPrimaryClip(clip)
                    result.success(null)
                } else result.notImplemented()
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.wencrypt.entry-image")
            .setMethodCallHandler { call, result ->
                if (call.method != "savePng") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val bytes = call.arguments as? ByteArray
                if (bytes == null || bytes.isEmpty()) {
                    result.error("invalid_image", null, null)
                    return@setMethodCallHandler
                }
                Thread {
                    val saved = runCatching { saveEntryImage(bytes) }.isSuccess
                    bytes.fill(0)
                    runOnUiThread { result.success(saved) }
                }.start()
            }

        ocrChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.wencrypt.ocr").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "takePendingImage" -> {
                        val pending = synchronized(pendingImageLock) {
                            val data = pendingSharedImage
                            pendingSharedImage = null
                            data
                        }
                        result.success(pending?.copyOf())
                        pending?.fill(0)
                    }
                    "readClipboardImage" -> {
                        Thread {
                            val bytes = ScreenshotOcr.readClipboardImage(applicationContext)
                            runOnUiThread {
                                result.success(bytes?.copyOf())
                                bytes?.fill(0)
                            }
                        }.start()
                    }
                    "readAndRecognizeClipboardImage" -> {
                        ScreenshotOcr.readAndRecognizeClipboardImage(
                            applicationContext,
                            onEmpty = {
                                runOnUiThread { result.success(mapOf("hasImage" to false)) }
                            },
                            onSuccess = { output ->
                                runOnUiThread { result.success(output) }
                            },
                            onError = { code ->
                                runOnUiThread { result.error(code, null, null) }
                            },
                        )
                    }
                    "recognizeImage" -> {
                        val bytes = call.arguments as? ByteArray
                        if (bytes == null || bytes.isEmpty()) {
                            result.error("invalid_image", null, null)
                            return@setMethodCallHandler
                        }
                        val copy = bytes.copyOf()
                        ScreenshotOcr.recognizeImage(
                            copy,
                            onSuccess = { output ->
                                runOnUiThread { result.success(output) }
                            },
                            onError = { code ->
                                runOnUiThread { result.error(code, null, null) }
                            },
                        )
                    }
                    else -> result.notImplemented()
                }
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.wencrypt.updater")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAppInfo" -> {
                        val info = runCatching {
                            @Suppress("DEPRECATION")
                            packageManager.getPackageInfo(packageName, 0)
                        }.getOrNull()
                        val version = info?.versionName ?: "0.3.11"
                        val buildNumber = if (info == null) {
                            "1"
                        } else if (android.os.Build.VERSION.SDK_INT >= 28) {
                            info.longVersionCode.toString()
                        } else {
                            @Suppress("DEPRECATION")
                            info.versionCode.toString()
                        }
                        result.success(
                            mapOf(
                                "version" to version,
                                "buildNumber" to buildNumber,
                                "installPath" to "",
                                "canAutoInstall" to false,
                                "isSandboxed" to false,
                                "platform" to "android",
                            )
                        )
                    }
                    "openUrl" -> {
                        val rawUrl = call.arguments as? String
                        if (rawUrl == null || !rawUrl.startsWith("https://")) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val opened = runCatching {
                            startActivity(Intent(Intent.ACTION_VIEW, android.net.Uri.parse(rawUrl)))
                            true
                        }.getOrDefault(false)
                        result.success(opened)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
