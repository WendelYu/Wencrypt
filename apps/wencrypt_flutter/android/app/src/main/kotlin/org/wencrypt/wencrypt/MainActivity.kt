package org.wencrypt.wencrypt

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var backupResult: MethodChannel.Result? = null
    private var backupBytes: ByteArray? = null
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 7401) return
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

    private val probe by lazy { DeviceProbe(this) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
                            putExtra(android.content.Intent.EXTRA_TITLE, "wencrypt-backup.wenback")
                        }, 7401)
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.wencrypt.p0/device")
            .setMethodCallHandler { call, result ->
                try {
                    probe.perform(call.method) { result.success(it) }
                } catch (_: Exception) {
                    result.error("probe_failed", "Android device probe unavailable", null)
                }
            }
    }
}
