import Foundation
import LocalAuthentication
import Security
import CryptoKit

// Public test data only. This is NOT a production vault unlock API.
final class DeviceProbe {
    private struct Envelope: Codable {
        let version: Int
        let hardwareKey: Data // Opaque, device-bound Secure Enclave representation.
        let peerPublicKey: Data
        let salt: Data
        let sealed: Data
    }
    private let marker = Data(repeating: 0xA5, count: 32)
    private let domain = Data("org.wencrypt.device-probe.ecdh-hkdf-aesgcm.v2".utf8)
    private let file: URL

    init(storageURL: URL? = nil) {
        file = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("org.wencrypt/device-probe-v2.json")
    }

    func perform(_ method: String) -> [String: Any] {
        do {
            switch method {
            case "capabilities":
                let context = LAContext()
                defer { context.invalidate() }
                var error: NSError?
                return ["platform": "macos", "hardwareAvailable": SecureEnclave.isAvailable,
                        "biometricAvailable": context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error),
                        "strictUnlockEnabled": false, "status": "Secure Enclave persistent P0 probe v2"]
            case "createProbe": return try create()
            case "unlockProbe": return try unlock(interactive: true)
            case "unlockProbeNonInteractive": return try unlock(interactive: false)
            case "resetProbe":
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                return ["status": "probe_removed", "unlocked": false]
            default: return failure("unsupported_operation")
            }
        } catch {
            // No plaintext, opaque key blob or OS error description enters logs.
            return ["status": "not_passed", "stage": "operation_failed_or_cancelled",
                    "errorDomain": (error as NSError).domain, "errorCode": (error as NSError).code,
                    "unlocked": false, "strictUnlockEnabled": false]
        }
    }

    private func create() throws -> [String: Any] {
        guard SecureEnclave.isAvailable else { return failure("secure_enclave_unavailable") }
        guard !FileManager.default.fileExists(atPath: file.path) else { return failure("probe_exists_reset_explicitly") }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet], &error) else { return failure("access_control") }
        let context = LAContext()
        defer { context.invalidate() }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access, authenticationContext: context)
        // Encrypt with the public key only. Ephemeral peer private key is never persisted.
        let peer = P256.KeyAgreement.PrivateKey()
        let salt = try random(32)
        let shared = try peer.sharedSecretFromKeyAgreement(with: key.publicKey)
        let wrappingKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: domain, outputByteCount: 32)
        let sealed = try AES.GCM.seal(marker, using: wrappingKey, authenticating: domain)
        let envelope = Envelope(version: 2, hardwareKey: key.dataRepresentation,
                                peerPublicKey: peer.publicKey.rawRepresentation, salt: salt, sealed: sealed.combined!)
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(envelope).write(to: file, options: [.withoutOverwriting])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return ["status": "wrapped_test_marker", "hardwareBacked": true, "strictUnlockEnabled": false, "unlocked": false]
    }

    private func unlock(interactive: Bool) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: file.path) else { return failure("create_probe_first") }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 && size <= 16384 else { return failure("invalid_envelope_size") }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: file))
        guard envelope.version == 2, envelope.salt.count == 32, envelope.peerPublicKey.count == 64,
              envelope.sealed.count == 60, !envelope.hardwareKey.isEmpty else { return failure("invalid_envelope") }
        let context = LAContext()
        context.localizedReason = "使用 Touch ID 解包 Wencrypt 测试数据"
        context.localizedFallbackTitle = ""
        context.touchIDAuthenticationAllowableReuseDuration = 0
        context.interactionNotAllowed = !interactive
        defer { context.invalidate() }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: envelope.hardwareKey, authenticationContext: context)
        let peer = try P256.KeyAgreement.PublicKey(rawRepresentation: envelope.peerPublicKey)
        let shared = try key.sharedSecretFromKeyAgreement(with: peer)
        let wrappingKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: envelope.salt, sharedInfo: domain, outputByteCount: 32)
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed), using: wrappingKey, authenticating: domain)
        guard plain == marker else { return failure("marker_mismatch") }
        return ["status": "authenticated_unwrap_passed", "hardwareBacked": true,
                "authenticationBound": true, "unlocked": true, "strictUnlockEnabled": false]
    }

    private func random(_ count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return bytes
    }

    private func failure(_ stage: String) -> [String: Any] {
        ["status": "not_passed", "stage": stage, "unlocked": false, "strictUnlockEnabled": false]
    }
}
