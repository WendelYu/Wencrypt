import Foundation
import CryptoKit
import LocalAuthentication
import Security

// This bridge never returns DEK bytes through Flutter.
final class NativeVaultBridge {
    private typealias Take = @convention(c) (UnsafePointer<UInt8>, Int, UnsafeMutablePointer<UInt8>) -> Int32
    private typealias Open = @convention(c) (UnsafePointer<UInt8>, Int, UnsafePointer<UInt8>, UInt64, UnsafeMutablePointer<UInt8>) -> Int32
    private let handle: UnsafeMutableRawPointer
    init(libraryPath: String? = nil) throws {
        let path = libraryPath ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libwencrypt_core.dylib").path
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { throw DeviceVaultError.failed }
        self.handle = handle
    }
    deinit { dlclose(handle) }
    func take(_ ticket: String) throws -> Data {
        guard let symbol = dlsym(handle, "wencrypt_device_take") else { throw DeviceVaultError.failed }
        let call = unsafeBitCast(symbol, to: Take.self)
        let input = Array(ticket.utf8)
        var output = Data(count:80)
        let result = input.withUnsafeBufferPointer { ticket in
            output.withUnsafeMutableBytes { body in call(ticket.baseAddress!,ticket.count,body.bindMemory(to:UInt8.self).baseAddress!) }
        }
        guard result == 0 else { output.resetBytes(in:0..<output.count); throw DeviceVaultError.failed }
        return output
    }
    func open(_ path: String, _ payload: Data, _ epoch: UInt64) throws -> String {
        guard payload.count == 80, let symbol=dlsym(handle,"wencrypt_device_open") else {throw DeviceVaultError.failed}
        let call=unsafeBitCast(symbol,to:Open.self)
        let path=Array(path.utf8); var output=[UInt8](repeating:0,count:32)
        let status=path.withUnsafeBufferPointer { path in payload.withUnsafeBytes { body in
            output.withUnsafeMutableBufferPointer { token in call(path.baseAddress!,path.count,body.bindMemory(to:UInt8.self).baseAddress!,epoch,token.baseAddress!) }
        }}
        guard status==0 else {throw DeviceVaultError.failed}
        return String(decoding:output,as:UTF8.self)
    }
    func backupGrant(_ payload: Data, _ epoch: UInt64) throws -> String {
        typealias Grant = @convention(c) (UnsafePointer<UInt8>, UInt64, UnsafeMutablePointer<UInt8>) -> Int32
        guard payload.count == 80, let symbol = dlsym(handle, "wencrypt_device_backup_grant") else {
            throw DeviceVaultError.failed
        }
        let call = unsafeBitCast(symbol, to: Grant.self)
        var output = [UInt8](repeating: 0, count: 32)
        let status = payload.withUnsafeBytes { body in
            output.withUnsafeMutableBufferPointer { ticket in
                call(body.bindMemory(to: UInt8.self).baseAddress!, epoch, ticket.baseAddress!)
            }
        }
        guard status == 0 else { throw DeviceVaultError.failed }
        return String(decoding: output, as: UTF8.self)
    }

}
enum DeviceVaultError: Error { case failed, cancelled }
final class DeviceVault {
    private struct Wrapped: Codable { let version:Int;let key:Data;let peer:Data;let salt:Data;let body:Data }
    private let mutex=NSLock()
    private var generation:UInt64=0
    private var context:LAContext?
    var currentGeneration:UInt64 {mutex.lock();defer{mutex.unlock()};return generation}
    func cancel(){mutex.lock();generation += 1;let active=context;mutex.unlock();active?.invalidate()}
    private func check(_ expected:UInt64)throws {if currentGeneration != expected {throw DeviceVaultError.cancelled}}
    private func file(_ binding:String)throws->URL {
        guard binding.count==64,binding.allSatisfy({"0123456789abcdef".contains($0)}) else {throw DeviceVaultError.failed}
        var directory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("org.wencrypt/device-unlock")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var values=URLResourceValues();values.isExcludedFromBackup=true;try directory.setResourceValues(values)
        return directory.appendingPathComponent(binding+".json")
    }
    private func info(_ binding:String)->Data {Data(("wencrypt-local-device-key-v1/"+binding).utf8)}
    private func unwrap(_ wrapped:Wrapped,_ binding:String,_ expected:UInt64, backup: Bool = false)throws->Data {
        guard wrapped.version==1,wrapped.peer.count==64,wrapped.salt.count==32,wrapped.body.count==108 else{throw DeviceVaultError.failed}
        try check(expected)
        let ctx=LAContext();ctx.localizedReason=backup ? "使用 Touch ID 授权导出 Wencrypt 加密备份" : "使用 Touch ID 解锁 Wencrypt 密码库";ctx.localizedFallbackTitle="";ctx.touchIDAuthenticationAllowableReuseDuration=0
        mutex.lock();context=ctx;mutex.unlock()
        defer{ctx.invalidate();mutex.lock();context=nil;mutex.unlock()}
        try check(expected)
        let key=try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation:wrapped.key,authenticationContext:ctx)
        let shared=try key.sharedSecretFromKeyAgreement(with:P256.KeyAgreement.PublicKey(rawRepresentation:wrapped.peer))
        let kek=shared.hkdfDerivedSymmetricKey(using:SHA256.self,salt:wrapped.salt,sharedInfo:info(binding),outputByteCount:32)
        try check(expected)
        return try AES.GCM.open(AES.GCM.SealedBox(combined:wrapped.body),using:kek,authenticating:info(binding))
    }
    func perform(_ method:String,_ args:[String:Any],generation expected:UInt64)->[String:Any] {
        do{
            try check(expected)
            guard let binding=args["binding"] as? String else {throw DeviceVaultError.failed}
            let url=try file(binding)
            if method=="status" {return ["enabled":FileManager.default.fileExists(atPath:url.path),"hardwareAvailable":SecureEnclave.isAvailable]}
            if method=="disable" {if FileManager.default.fileExists(atPath:url.path){try FileManager.default.removeItem(at:url)};return ["enabled":false]}
            guard SecureEnclave.isAvailable else{throw DeviceVaultError.failed}
            let bridge=try NativeVaultBridge()
            if method=="enable" {
                guard let ticket=args["ticket"] as? String else{throw DeviceVaultError.failed}
                var payload=try bridge.take(ticket);defer{payload.resetBytes(in:0..<payload.count)}
                var error:Unmanaged<CFError>?
                guard let access=SecAccessControlCreateWithFlags(nil,kSecAttrAccessibleWhenUnlockedThisDeviceOnly,[.privateKeyUsage,.biometryCurrentSet],&error) else{throw DeviceVaultError.failed}
                let key=try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl:access)
                let peer=P256.KeyAgreement.PrivateKey()
                var salt=Data(count:32)
                let status=salt.withUnsafeMutableBytes{SecRandomCopyBytes(kSecRandomDefault,32,$0.baseAddress!)}
                guard status==errSecSuccess else{throw DeviceVaultError.failed}
                let shared=try peer.sharedSecretFromKeyAgreement(with:key.publicKey)
                let kek=shared.hkdfDerivedSymmetricKey(using:SHA256.self,salt:salt,sharedInfo:info(binding),outputByteCount:32)
                let body=try AES.GCM.seal(payload,using:kek,authenticating:info(binding)).combined!
                let wrapped=Wrapped(version:1,key:key.dataRepresentation,peer:peer.publicKey.rawRepresentation,salt:salt,body:body)
                var verified=try unwrap(wrapped,binding,expected);defer{verified.resetBytes(in:0..<verified.count)}
                guard verified==payload else{throw DeviceVaultError.failed}
                try check(expected)
                try JSONEncoder().encode(wrapped).write(to:url,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
                return ["enabled":true]
            }
            if method == "unlock" || method == "authorizeBackup" {
                guard let epoch = args["epoch"] as? NSNumber else { throw DeviceVaultError.failed }
                let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                guard size>0,size<16384 else{throw DeviceVaultError.failed}
                let wrapped=try JSONDecoder().decode(Wrapped.self,from:Data(contentsOf:url))
                let backup = method == "authorizeBackup"
                var payload = try unwrap(wrapped, binding, expected, backup: backup)
                defer { payload.resetBytes(in: 0..<payload.count) }
                try check(expected)
                if backup {
                    return ["ticket": try bridge.backupGrant(payload, epoch.uint64Value)]
                }
                guard let path = args["path"] as? String else { throw DeviceVaultError.failed }
                return ["session": try bridge.open(path, payload, epoch.uint64Value)]
            }
            throw DeviceVaultError.failed
        }catch{return ["error":"biometric_cancelled_invalidated_or_failed"]}
    }
}
