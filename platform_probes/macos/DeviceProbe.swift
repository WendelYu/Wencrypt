import Foundation
import LocalAuthentication
import Security
import CryptoKit

// PUBLIC TEST DATA only. Never accepts or returns a vault DEK.
final class DeviceProbe {
    private let tag = Data("org.wencrypt.p0.secure-enclave.v1".utf8)
    private let blobKey = "org.wencrypt.p0.wrapped-test.v1"
    private let marker = Data(repeating: 0xA5, count: 32)
    private let algorithm = SecKeyAlgorithm.eciesEncryptionCofactorX963SHA256AESGCM

    func perform(_ method: String) -> [String: Any] {
        switch method {
        case "capabilities":
            let context = LAContext()
            defer { context.invalidate() }
            var error: NSError?
            let biometric = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
            return ["platform": "macos", "biometricAvailable": biometric,
                    "hardwareAvailable": SecureEnclave.isAvailable,
                    "strictUnlockEnabled": false,
                    "status": "P0 probe only; creation and authenticated unwrap still required"]
        case "createProbe": return create()
        case "unlockProbe": return unlock()
        case "resetProbe":
            let status = SecItemDelete(([kSecClass: kSecClassKey, kSecAttrApplicationTag: tag, kSecUseDataProtectionKeychain: true] as [CFString: Any]) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { return failure("reset", Int(status)) }
            UserDefaults.standard.removeObject(forKey: blobKey)
            return ["status": "probe_removed"]
        default: return failure("unsupported_operation")
        }
    }

    private func create() -> [String: Any] {
        guard SecureEnclave.isAvailable else { return failure("secure_enclave_unavailable") }
        guard UserDefaults.standard.data(forKey: blobKey) == nil else { return failure("probe_exists_reset_explicitly") }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet], &error) else { return failure("access_control") }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecAttrTokenID: kSecAttrTokenIDSecureEnclave,
            kSecUseDataProtectionKeychain: true,
            kSecPrivateKeyAttrs: [kSecAttrIsPermanent: true, kSecAttrApplicationTag: tag, kSecAttrAccessControl: access] as [CFString: Any]
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(key) else { return failure("secure_key_creation", error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? 0) }
        guard SecKeyIsAlgorithmSupported(publicKey, .encrypt, algorithm),
              let encrypted = SecKeyCreateEncryptedData(publicKey, algorithm, marker as CFData, &error) else {
            _ = SecItemDelete(([kSecClass: kSecClassKey, kSecAttrApplicationTag: tag, kSecUseDataProtectionKeychain: true] as [CFString: Any]) as CFDictionary)
            return failure("wrap")
        }
        UserDefaults.standard.set(encrypted as Data, forKey: blobKey)
        return ["status": "wrapped_test_marker", "hardwareBacked": true,
                "policy": "SecureEnclave + biometryCurrentSet + privateKeyUsage",
                "strictUnlockEnabled": false]
    }

    private func unlock() -> [String: Any] {
        guard let wrapped = UserDefaults.standard.data(forKey: blobKey) else { return failure("create_probe_first") }
        let context = LAContext()
        context.localizedReason = "验证 Wencrypt 测试密钥，不读取真实密码"
        context.touchIDAuthenticationAllowableReuseDuration = 0
        defer { context.invalidate() }
        let query: [CFString: Any] = [kSecClass: kSecClassKey, kSecAttrApplicationTag: tag,
                                    kSecReturnRef: true, kSecUseDataProtectionKeychain: true, kSecUseAuthenticationContext: context]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let item else { return failure("key_lookup_or_authentication", Int(status)) }
        let key = item as! SecKey
        var error: Unmanaged<CFError>?
        guard let plain = SecKeyCreateDecryptedData(key, algorithm, wrapped as CFData, &error) else {
            return failure("authenticated_unwrap_cancelled_or_failed")
        }
        guard (plain as Data) == marker else { return failure("marker_mismatch") }
        return ["status": "authenticated_unwrap_passed", "hardwareBacked": true,
                "strictUnlockEnabled": false, "remaining": "cancel/lock/reboot/enrollment matrix"]
    }

    private func failure(_ stage: String, _ code: Int = 0) -> [String: Any] {
        ["status": "not_passed", "stage": stage, "osStatus": code, "strictUnlockEnabled": false]
    }
}
