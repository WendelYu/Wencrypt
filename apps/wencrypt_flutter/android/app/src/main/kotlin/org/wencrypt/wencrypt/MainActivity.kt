package org.wencrypt.wencrypt

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val probe by lazy { DeviceProbe(this) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
