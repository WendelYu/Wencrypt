package org.wencrypt.wencrypt

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec

// Only a fixed PUBLIC test marker is processed; no vault key crosses Flutter.
class DeviceProbe(private val activity: FragmentActivity) {
    private val alias = "org.wencrypt.p0.test.v1"
    private val prefs = activity.getSharedPreferences("wencrypt_p0_probe", Context.MODE_PRIVATE)
    private val marker = ByteArray(32) { 0xA5.toByte() }
    private var busy = false
    private var activePrompt: BiometricPrompt? = null
    private val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    fun perform(method: String, result: (Map<String, Any>) -> Unit) {
        if (busy) { result(fail("probe_busy")); return }
        when (method) {
            "capabilities" -> result(mapOf("platform" to "android",
                "biometricAvailable" to (BiometricManager.from(activity).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) == BiometricManager.BIOMETRIC_SUCCESS),
                "strictUnlockEnabled" to false, "status" to "P0 only; hardware checked after key generation"))
            "resetProbe" -> try { keyStore.deleteEntry(alias); prefs.edit().clear().commit(); result(mapOf("status" to "probe_removed")) } catch (_: Exception) { result(fail("reset")) }
            "createProbe" -> authenticate(true, result)
            "unlockProbe" -> authenticate(false, result)
            else -> result(fail("unsupported_operation"))
        }
    }

    fun cancel() { activePrompt?.cancelAuthentication() }

    private fun authenticate(create: Boolean, result: (Map<String, Any>) -> Unit) {
        try {
            if (create && keyStore.containsAlias(alias)) { result(fail("probe_exists_reset_explicitly")); return }
            if (create) {
                val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256).setUserAuthenticationRequired(true).setInvalidatedByBiometricEnrollment(true)
                if (Build.VERSION.SDK_INT >= 30) spec.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
                else { @Suppress("DEPRECATION") spec.setUserAuthenticationValidityDurationSeconds(-1) }
                KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply { init(spec.build()); generateKey() }
            }
            val key = keyStore.getKey(alias, null) as? SecretKey ?: run { result(fail("create_probe_first")); return }
            val info = SecretKeyFactory.getInstance(key.algorithm, "AndroidKeyStore").getKeySpec(key, KeyInfo::class.java) as KeyInfo
            @Suppress("DEPRECATION")
            val hardware = if (Build.VERSION.SDK_INT >= 31) info.securityLevel == KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT || info.securityLevel == KeyProperties.SECURITY_LEVEL_STRONGBOX else info.isInsideSecureHardware
            if (!hardware) { keyStore.deleteEntry(alias); prefs.edit().clear().commit(); result(fail("hardware_backing_unavailable")); return }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            if (create) cipher.init(Cipher.ENCRYPT_MODE, key)
            else {
                val iv = prefs.getString("iv", null) ?: run { result(fail("create_probe_first")); return }
                cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP)))
            }
            busy = true
            var finished = false
            fun finish(value: Map<String, Any>) { if (!finished) { finished = true; busy = false; activePrompt = null; result(value) } }
            val prompt = BiometricPrompt(activity, ContextCompat.getMainExecutor(activity), object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationError(code: Int, message: CharSequence) { finish(fail("authentication_cancelled_or_failed", code)) }
                override fun onAuthenticationSucceeded(auth: BiometricPrompt.AuthenticationResult) {
                    try {
                        val authorized = auth.cryptoObject?.cipher ?: run { finish(fail("missing_crypto_object")); return }
                        if (create) {
                            val wrapped = authorized.doFinal(marker)
                            val saved = prefs.edit().putString("iv", Base64.encodeToString(authorized.iv, Base64.NO_WRAP))
                                .putString("wrapped", Base64.encodeToString(wrapped, Base64.NO_WRAP)).commit()
                            finish(if (saved) mapOf("status" to "wrapped_test_marker", "hardwareBacked" to hardware, "strictUnlockEnabled" to false) else fail("save"))
                        } else {
                            val value = prefs.getString("wrapped", null) ?: run { finish(fail("missing_wrapped_marker")); return }
                            val plain = authorized.doFinal(Base64.decode(value, Base64.NO_WRAP))
                            val matches = java.security.MessageDigest.isEqual(plain, marker); plain.fill(0)
                            finish(if (matches) mapOf("status" to "authenticated_unwrap_passed", "hardwareBacked" to hardware, "strictUnlockEnabled" to false) else fail("marker_mismatch"))
                        }
                    } catch (_: Exception) { finish(fail("crypto_or_key_invalidated")) }
                }
            })
            activePrompt = prompt
            val promptInfo = BiometricPrompt.PromptInfo.Builder().setTitle("Wencrypt 测试密钥验证")
                .setSubtitle("仅处理公开测试数据")
                .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                .setNegativeButtonText("取消").build()
            prompt.authenticate(promptInfo, BiometricPrompt.CryptoObject(cipher))
        } catch (_: Exception) { busy = false; activePrompt = null; result(fail("key_or_crypto_unavailable")) }
    }
    private fun fail(stage: String, code: Int = 0): Map<String, Any> = mapOf("status" to "not_passed", "stage" to stage, "code" to code, "strictUnlockEnabled" to false)
}
