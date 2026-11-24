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
    private fun biometricStatusName(): String =
        when (BiometricManager.from(activity).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)) {
            BiometricManager.BIOMETRIC_SUCCESS -> "ready"
            BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> "none_enrolled"
            BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE,
            BiometricManager.BIOMETRIC_ERROR_SECURITY_UPDATE_REQUIRED -> "no_hardware"
            else -> "unavailable"
        }

    private fun unavailableErrorCode(): String? =
        when (biometricStatusName()) {
            "ready" -> null
            "none_enrolled" -> "biometric_not_enrolled"
            "no_hardware" -> "biometric_no_hardware"
            else -> "biometric_unavailable"
        }

    private fun errorCodeForPrompt(code: Int): String =
        when (code) {
            BiometricPrompt.ERROR_USER_CANCELED,
            BiometricPrompt.ERROR_NEGATIVE_BUTTON,
            BiometricPrompt.ERROR_CANCELED -> "biometric_cancelled"
            BiometricPrompt.ERROR_LOCKOUT,
            BiometricPrompt.ERROR_LOCKOUT_PERMANENT -> "biometric_lockout"
            BiometricPrompt.ERROR_NO_BIOMETRICS -> "biometric_not_enrolled"
            BiometricPrompt.ERROR_HW_NOT_PRESENT,
            BiometricPrompt.ERROR_HW_UNAVAILABLE -> "biometric_unavailable"
            else -> "biometric_failed"
        }

    fun perform(method: String, args: Map<String, Any?>, done: (Map<String, Any>) -> Unit) {
        if (method == "cancel") { cancel(); done(emptyMap()); return }
        if (busy) { done(mapOf("error" to "biometric_busy")); return }
        var newAlias: String? = null
        val create = method == "enable"
        var previous: JSONObject? = null
        var target: File? = null
        try {
            val binding = args["binding"] as String
            val resolvedTarget = file(binding)
            target = resolvedTarget
            if (method == "status") {
                val statusName = biometricStatusName()
                done(
                    mapOf(
                        "enabled" to resolvedTarget.exists(),
                        "hardwareAvailable" to (statusName == "ready"),
                        "biometricStatus" to statusName,
                    ),
                )
                return
            }
            if (method == "disable") {
                if (resolvedTarget.exists()) {
                    val alias = read(resolvedTarget).getString("alias")
                    store.deleteEntry(alias)
                    check(resolvedTarget.delete())
                }
                done(mapOf("enabled" to false))
                return
            }
            require(method == "enable" || method == "unlock" || method == "authorizeBackup")
            unavailableErrorCode()?.let { error ->
                done(mapOf("error" to error))
                return
            }
            val backup = method == "authorizeBackup"
            previous = if (resolvedTarget.exists()) read(resolvedTarget) else null
            if (!create && previous == null) {
                done(mapOf("error" to "biometric_failed"))
                return
            }
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
            val hardware = if (Build.VERSION.SDK_INT >= 31) {
                info.securityLevel == KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT ||
                    info.securityLevel == KeyProperties.SECURITY_LEVEL_STRONGBOX ||
                    info.securityLevel == KeyProperties.SECURITY_LEVEL_UNKNOWN_SECURE
            } else {
                info.isInsideSecureHardware
            }
            if (!hardware || !info.isUserAuthenticationRequired) {
                if (create) {
                    runCatching { store.deleteEntry(alias) }
                }
                done(mapOf("error" to "biometric_no_hardware"))
                return
            }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            if (create) cipher.init(Cipher.ENCRYPT_MODE, key)
            else {
                require(previous!!.getInt("version") == 1)
                cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, Base64.decode(previous.getString("iv"), Base64.NO_WRAP)))
            }
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
                override fun onAuthenticationError(code: Int, message: CharSequence) {
                    finish(mapOf("error" to errorCodeForPrompt(code)))
                }
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    var plain: ByteArray? = null
                    try {
                        check(expected == generation)
                        val authorized = result.cryptoObject?.cipher ?: error("biometric_failed")
                        authorized.updateAAD("wencrypt-local-device-key-v1/$binding".toByteArray(Charsets.UTF_8))
                        if (create) {
                            val grantPlain = NativeVaultBridge.take(args["ticket"] as String)
                            if (grantPlain == null) {
                                finish(mapOf("error" to "biometric_grant_expired"))
                                return
                            }
                            plain = grantPlain
                            check(grantPlain.size == 80)
                            val sealed = authorized.doFinal(grantPlain)
                            val json = JSONObject().put("version", 1).put("alias", alias)
                                .put("iv", Base64.encodeToString(authorized.iv, Base64.NO_WRAP))
                                .put("body", Base64.encodeToString(sealed, Base64.NO_WRAP))
                            val atomic = android.util.AtomicFile(resolvedTarget)
                            val stream = atomic.startWrite()
                            try { stream.write(json.toString().toByteArray(Charsets.UTF_8)); atomic.finishWrite(stream) }
                            catch (e: Exception) { atomic.failWrite(stream); throw e }
                            if (previous != null) { try { store.deleteEntry(previous.getString("alias")) } catch (_: Exception) {} }
                            finish(mapOf("enabled" to true))
                        } else {
                            val sealed = Base64.decode(previous!!.getString("body"), Base64.NO_WRAP)
                            require(sealed.size == 96)
                            val openedPlain = authorized.doFinal(sealed)
                            plain = openedPlain
                            val epoch = (args["epoch"] as Number).toLong()
                            if (backup) {
                                val ticket = NativeVaultBridge.backupGrant(openedPlain, epoch)
                                if (ticket == null) {
                                    finish(mapOf("error" to "biometric_reauth_required"))
                                    return
                                }
                                finish(mapOf("ticket" to ticket))
                            } else {
                                val token = NativeVaultBridge.open(args["path"] as String, openedPlain, epoch)
                                if (token == null) {
                                    finish(mapOf("error" to "biometric_reauth_required"))
                                    return
                                }
                                finish(mapOf("session" to token))
                            }
                        }
                    } catch (_: Exception) {
                        finish(mapOf("error" to "biometric_failed"))
                    } finally {
                        plain?.fill(0)
                    }
                }
            })
            prompt = biometric
            val (title, negativeText) = when {
                create -> "开启指纹解锁" to "取消"
                backup -> "验证指纹以导出备份" to "取消"
                else -> "指纹解锁 Wencrypt" to "使用主密码"
            }
            biometric.authenticate(
                BiometricPrompt.PromptInfo.Builder()
                    .setTitle(title)
                    .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                    .setNegativeButtonText(negativeText)
                    .build(),
                BiometricPrompt.CryptoObject(cipher),
            )
        } catch (_: android.security.keystore.KeyPermanentlyInvalidatedException) {
            if (!create && previous != null) {
                runCatching { store.deleteEntry(previous.getString("alias")) }
                runCatching { target?.delete() }
            }
            busy = false; prompt = null
            done(mapOf("error" to "biometric_invalidated"))
        } catch (_: Exception) {
            newAlias?.let { try { store.deleteEntry(it) } catch (_: Exception) {} }
            busy = false; prompt = null
            done(mapOf("error" to "biometric_failed"))
        }
    }
}
