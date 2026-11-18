package org.wencrypt.wencrypt

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec

object NativeVaultBridge {
    init { System.loadLibrary("wencrypt_core") }
    external fun take(ticket: String): ByteArray?
    external fun open(path: String, payload: ByteArray, epoch: Long): String?
    external fun backupGrant(payload: ByteArray, epoch: Long): String?
}

// Only ciphertext, opaque tickets and session identifiers cross the Flutter channel.
class DeviceVault(private val activity: FragmentActivity) {
    private val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private var prompt: BiometricPrompt? = null
    private var generation = 0L
    private var busy = false
    fun cancel() { generation++; prompt?.cancelAuthentication() }
    private fun file(binding: String): File {
        require(Regex("[0-9a-f]{64}").matches(binding))
        val directory = File(activity.noBackupFilesDir, "device-unlock").apply { mkdirs() }
        return File(directory, "$binding.json")
    }
    private fun read(file: File): JSONObject {
        require(file.length() in 1..16384)
        return JSONObject(file.readText())
    }
    fun perform(method: String, args: Map<String, Any?>, done: (Map<String, Any>) -> Unit) {
        if (method == "cancel") { cancel(); done(emptyMap()); return }
        if (busy) { done(mapOf("error" to "biometric_busy")); return }
        var newAlias: String? = null
        try {
            val binding = args["binding"] as String
            val target = file(binding)
            if (method == "status") {
                done(mapOf("enabled" to target.exists(), "hardwareAvailable" to (BiometricManager.from(activity).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) == BiometricManager.BIOMETRIC_SUCCESS)))
                return
            }
            if (method == "disable") {
                if (target.exists()) { val alias=read(target).getString("alias"); store.deleteEntry(alias); check(target.delete()) }
                done(mapOf("enabled" to false)); return
            }
            require(method == "enable" || method == "unlock" || method == "authorizeBackup")
            val create = method == "enable"
            val backup = method == "authorizeBackup"
            val previous = if (target.exists()) read(target) else null
            val alias = if (create) "org.wencrypt.device.${UUID.randomUUID()}" else previous!!.getString("alias")
            if (create) {
                newAlias = alias
                val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256).setUserAuthenticationRequired(true).setInvalidatedByBiometricEnrollment(true)
                if (Build.VERSION.SDK_INT >= 30) spec.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
                else { @Suppress("DEPRECATION") spec.setUserAuthenticationValidityDurationSeconds(-1) }
                KeyGenerator.getInstance("AES", "AndroidKeyStore").apply { init(spec.build()); generateKey() }
            }
            val key = store.getKey(alias, null) as SecretKey
            val info = SecretKeyFactory.getInstance("AES", "AndroidKeyStore").getKeySpec(key, KeyInfo::class.java) as KeyInfo
            @Suppress("DEPRECATION")
            val hardware = if (Build.VERSION.SDK_INT >= 31) info.securityLevel == KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT || info.securityLevel == KeyProperties.SECURITY_LEVEL_STRONGBOX else info.isInsideSecureHardware
            check(hardware && info.isUserAuthenticationRequired)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            if (create) cipher.init(Cipher.ENCRYPT_MODE, key)
            else { require(previous!!.getInt("version") == 1); cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, Base64.decode(previous.getString("iv"), Base64.NO_WRAP))) }
            busy = true
            val expected = generation
            var finished = false
            fun finish(response: Map<String, Any>) {
                if (finished) return
                finished = true; busy = false; prompt = null
                if (response.containsKey("error") && create) { try { store.deleteEntry(alias) } catch (_: Exception) {} }
                done(response)
            }
            val biometric = BiometricPrompt(activity, ContextCompat.getMainExecutor(activity), object: BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationError(code: Int, message: CharSequence) { finish(mapOf("error" to "biometric_cancelled_invalidated_or_failed")) }
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    var plain: ByteArray? = null
                    try {
                        check(expected == generation)
                        val authorized = result.cryptoObject?.cipher ?: error("no_crypto_object")
                        authorized.updateAAD("wencrypt-local-device-key-v1/$binding".toByteArray(Charsets.UTF_8))
                        if (create) {
                            plain = NativeVaultBridge.take(args["ticket"] as String) ?: error("grant_expired")
                            check(plain!!.size == 80)
                            val sealed = authorized.doFinal(plain)
                            val json = JSONObject().put("version", 1).put("alias", alias)
                                .put("iv", Base64.encodeToString(authorized.iv, Base64.NO_WRAP))
                                .put("body", Base64.encodeToString(sealed, Base64.NO_WRAP))
                            val atomic = android.util.AtomicFile(target)
                            val stream = atomic.startWrite()
                            try { stream.write(json.toString().toByteArray(Charsets.UTF_8)); atomic.finishWrite(stream) }
                            catch (e: Exception) { atomic.failWrite(stream); throw e }
                            if (previous != null) { try { store.deleteEntry(previous.getString("alias")) } catch (_: Exception) {} }
                            finish(mapOf("enabled" to true))
                        } else {
                            val sealed=Base64.decode(previous!!.getString("body"), Base64.NO_WRAP)
                            require(sealed.size == 96)
                            plain = authorized.doFinal(sealed)
                            val epoch = (args["epoch"] as Number).toLong()
                            if (backup) {
                                val ticket = NativeVaultBridge.backupGrant(plain!!, epoch) ?: error("session_expired")
                                finish(mapOf("ticket" to ticket))
                            } else {
                                val token = NativeVaultBridge.open(args["path"] as String, plain!!, epoch) ?: error("session_expired")
                                finish(mapOf("session" to token))
                            }
                        }
                    } catch (_: Exception) { finish(mapOf("error" to "biometric_cancelled_invalidated_or_failed")) }
                    finally { plain?.fill(0) }
                }
            })
            prompt = biometric
            val title = when {
                create -> "为 Wencrypt 启用指纹解锁"
                backup -> "授权导出 Wencrypt 加密备份"
                else -> "解锁 Wencrypt 密码库"
            }
            biometric.authenticate(BiometricPrompt.PromptInfo.Builder().setTitle(title)
                .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG).setNegativeButtonText("取消").build(), BiometricPrompt.CryptoObject(cipher))
        } catch (_: Exception) {
            newAlias?.let { try { store.deleteEntry(it) } catch (_: Exception) {} }
            busy=false;prompt=null;done(mapOf("error" to "biometric_cancelled_invalidated_or_failed"))
        }
    }
}
