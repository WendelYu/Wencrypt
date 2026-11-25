import Cocoa
import FlutterMacOS
import ObjectiveC.runtime
import Testing
@testable import wencrypt

private final class UnpatchedAccessibleNodeStub: NSObject {}

private final class ExistingEditableNodeStub: NSObject {
  var didStartEditing = false

  @objc func startEditing() {
    didStartEditing = true
  }
}

struct RunnerTests {
  @Test func axPlatformNodeCocoaRespondsToStartEditing() {
    FlutterAccessibilityGuard.install()

    let selector = NSSelectorFromString("startEditing")
    let axNodeClass: AnyClass? = NSClassFromString("AXPlatformNodeCocoa")
    #expect(axNodeClass != nil)
    guard let axNodeClass else { return }

    #expect(class_respondsToSelector(axNodeClass, selector))
    let method = class_getInstanceMethod(axNodeClass, selector)
    #expect(method != nil)
    guard let method else { return }

    #expect(method_getNumberOfArguments(method) == 2)
    let returnTypePtr = method_copyReturnType(method)
    defer { free(returnTypePtr) }
    #expect(String(cString: returnTypePtr).hasPrefix("v"))
  }

  @Test func installNoopStartEditingAddsMethodIdempotentlyAndPreservesExisting() {
    let selector = NSSelectorFromString("startEditing")

    let unpatched = UnpatchedAccessibleNodeStub()
    #expect(!unpatched.responds(to: selector))
    #expect(FlutterAccessibilityGuard.installNoopStartEditing(on: UnpatchedAccessibleNodeStub.self))
    #expect(unpatched.responds(to: selector))
    _ = unpatched.perform(selector)
    #expect(!FlutterAccessibilityGuard.installNoopStartEditing(on: UnpatchedAccessibleNodeStub.self))

    let existing = ExistingEditableNodeStub()
    #expect(existing.responds(to: selector))
    #expect(!FlutterAccessibilityGuard.installNoopStartEditing(on: ExistingEditableNodeStub.self))
    _ = existing.perform(selector)
    #expect(existing.didStartEditing)
  }

  @Test func sandboxDataMigratorCopiesLegacyVaultAndDeviceUnlockWithoutOverwriting() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("wencrypt-mig-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    let legacyRoot = root.appendingPathComponent("legacy", isDirectory: true)
    let targetRoot = root.appendingPathComponent("target", isDirectory: true)
    let legacyVaultDir = legacyRoot.appendingPathComponent("org.wencrypt.wencrypt", isDirectory: true)
    let legacyUnlockDir = legacyRoot.appendingPathComponent("org.wencrypt/device-unlock", isDirectory: true)
    try fm.createDirectory(at: legacyVaultDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: legacyUnlockDir, withIntermediateDirectories: true)

    let legacyDb = legacyVaultDir.appendingPathComponent("wencrypt-alpha.db")
    let legacyPrefs = legacyVaultDir.appendingPathComponent("app-update-prefs.json")
    let staleLock = legacyVaultDir.appendingPathComponent("sync.lock")
    let staleTmp = legacyVaultDir.appendingPathComponent("sync.tmp")
    let legacyKey = legacyUnlockDir.appendingPathComponent("abcd.json")

    try Data("legacy-vault-db".utf8).write(to: legacyDb)
    try Data("{\"autoCheckEnabled\":false}".utf8).write(to: legacyPrefs)
    try Data("lock".utf8).write(to: staleLock)
    try Data("tmp".utf8).write(to: staleTmp)
    try Data("{\"version\":1}".utf8).write(to: legacyKey)

    #expect(!SandboxDataMigrator.migrateIfNeeded(
      legacyContainerRoot: legacyRoot,
      targetAppSupportRoot: targetRoot,
      isSandboxed: true
    ))

    #expect(SandboxDataMigrator.migrateIfNeeded(
      legacyContainerRoot: legacyRoot,
      targetAppSupportRoot: targetRoot,
      isSandboxed: false
    ))

    let targetVaultDir = targetRoot.appendingPathComponent("org.wencrypt.wencrypt", isDirectory: true)
    let targetDb = targetVaultDir.appendingPathComponent("wencrypt-alpha.db")
    let targetPrefs = targetVaultDir.appendingPathComponent("app-update-prefs.json")
    let targetKey = targetRoot.appendingPathComponent("org.wencrypt/device-unlock/abcd.json")

    #expect(try String(contentsOf: targetDb, encoding: .utf8) == "legacy-vault-db")
    #expect(fm.fileExists(atPath: targetPrefs.path))
    #expect(fm.fileExists(atPath: targetKey.path))
    #expect(!fm.fileExists(atPath: targetVaultDir.appendingPathComponent("sync.lock").path))
    #expect(!fm.fileExists(atPath: targetVaultDir.appendingPathComponent("sync.tmp").path))
    #expect(fm.fileExists(atPath: legacyDb.path))

    try Data("newer-target-db".utf8).write(to: targetDb)
    #expect(!SandboxDataMigrator.migrateIfNeeded(
      legacyContainerRoot: legacyRoot,
      targetAppSupportRoot: targetRoot,
      isSandboxed: false
    ))
    #expect(try String(contentsOf: targetDb, encoding: .utf8) == "newer-target-db")
  }

  @Test func appUpdaterVerifiesSha256AndRejectsMismatch() throws {
    let fm = FileManager.default
    let fileURL = fm.temporaryDirectory.appendingPathComponent("wencrypt-sha-\(UUID().uuidString).bin")
    defer { try? fm.removeItem(at: fileURL) }
    try Data("abc".utf8).write(to: fileURL)

    let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    #expect(try AppUpdater.sha256Hex(of: fileURL) == expected)
    try AppUpdater.verifyZipSha256(archiveURL: fileURL, expectedHex: expected.uppercased())

    var failedWithMismatch = false
    do {
      try AppUpdater.verifyZipSha256(archiveURL: fileURL, expectedHex: String(repeating: "0", count: 64))
    } catch AppUpdaterError.checksumMismatch {
      failedWithMismatch = true
    }
    #expect(failedWithMismatch)
  }

  @Test func appUpdaterCanAutoInstallChecksLocationAndSandbox() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("wencrypt-writable-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)

    let writableApp = root.appendingPathComponent("wencrypt.app", isDirectory: true)
    #expect(AppUpdater.canAutoInstall(bundleURL: writableApp, isSandboxed: false))
    #expect(!AppUpdater.canAutoInstall(bundleURL: writableApp, isSandboxed: true))
    #expect(!AppUpdater.canAutoInstall(
      bundleURL: URL(fileURLWithPath: "/Volumes/Wencrypt/wencrypt.app"),
      isSandboxed: false
    ))
    #expect(!AppUpdater.canAutoInstall(
      bundleURL: URL(fileURLWithPath: "/private/var/folders/xx/AppTranslocation/AA/d/wencrypt.app"),
      isSandboxed: false
    ))
  }

  @Test func appUpdaterExtractAndValidateBundleChecksBundleIdAndSignature() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("wencrypt-bundle-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    let dummyApp = root.appendingPathComponent("src/wencrypt.app", isDirectory: true)
    let macOsDir = dummyApp.appendingPathComponent("Contents/MacOS", isDirectory: true)
    try fm.createDirectory(at: macOsDir, withIntermediateDirectories: true)

    let plist: [String: Any] = [
      "CFBundleIdentifier": "org.wencrypt.wencrypt",
      "CFBundleExecutable": "wencrypt",
      "CFBundlePackageType": "APPL",
      "CFBundleShortVersionString": "0.4.0",
      "CFBundleVersion": "22",
    ]
    let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try plistData.write(to: dummyApp.appendingPathComponent("Contents/Info.plist"))

    let exe = macOsDir.appendingPathComponent("wencrypt")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: exe)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

    func run(_ exePath: String, _ args: [String]) -> Int32 {
      let proc = Process()
      proc.executableURL = URL(fileURLWithPath: exePath)
      proc.arguments = args
      try? proc.run()
      proc.waitUntilExit()
      return proc.terminationStatus
    }

    #expect(run("/usr/bin/codesign", ["--force", "--sign", "-", dummyApp.path]) == 0)
    let zipURL = root.appendingPathComponent("wencrypt.zip")
    #expect(run("/usr/bin/ditto", ["-c", "-k", "--keepParent", dummyApp.path, zipURL.path]) == 0)

    let workValid = root.appendingPathComponent("work-valid", isDirectory: true)
    let extracted = try AppUpdater.extractAndValidateBundle(
      archiveURL: zipURL,
      expectedBundleIdentifier: "org.wencrypt.wencrypt",
      workDir: workValid,
      requireCoreLibrary: false
    )
    #expect(extracted.lastPathComponent == "wencrypt.app")

    let workMismatch = root.appendingPathComponent("work-mismatch", isDirectory: true)
    var rejectedWrongId = false
    do {
      _ = try AppUpdater.extractAndValidateBundle(
        archiveURL: zipURL,
        expectedBundleIdentifier: "com.example.other",
        workDir: workMismatch,
        requireCoreLibrary: false
      )
    } catch AppUpdaterError.bundleValidationFailed {
      rejectedWrongId = true;
    }
    #expect(rejectedWrongId)
  }

  @Test func appUpdaterExtractAndValidateDmgBundleChecksBundleIdAndSignature() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("wencrypt-dmg-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    let staging = root.appendingPathComponent("staging", isDirectory: true)
    let dummyApp = staging.appendingPathComponent("wencrypt.app", isDirectory: true)
    let macOsDir = dummyApp.appendingPathComponent("Contents/MacOS", isDirectory: true)
    try fm.createDirectory(at: macOsDir, withIntermediateDirectories: true)

    let plist: [String: Any] = [
      "CFBundleIdentifier": "org.wencrypt.wencrypt",
      "CFBundleExecutable": "wencrypt",
      "CFBundlePackageType": "APPL",
      "CFBundleShortVersionString": "0.4.0",
      "CFBundleVersion": "22",
    ]
    let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try plistData.write(to: dummyApp.appendingPathComponent("Contents/Info.plist"))

    let exe = macOsDir.appendingPathComponent("wencrypt")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: exe)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

    func run(_ exePath: String, _ args: [String]) -> Int32 {
      let proc = Process()
      proc.executableURL = URL(fileURLWithPath: exePath)
      proc.arguments = args
      try? proc.run()
      proc.waitUntilExit()
      return proc.terminationStatus
    }

    #expect(run("/usr/bin/codesign", ["--force", "--sign", "-", dummyApp.path]) == 0)
    let dmgURL = root.appendingPathComponent("wencrypt-v0.4.0-macos-arm64.dmg")
    #expect(run(
      "/usr/bin/hdiutil",
      ["create", "-ov", "-volname", "Wencrypt", "-srcfolder", staging.path, "-fs", "HFS+", "-format", "UDZO", dmgURL.path]
    ) == 0)

    let workValid = root.appendingPathComponent("work-dmg-valid", isDirectory: true)
    let extracted = try AppUpdater.extractAndValidateBundle(
      archiveURL: dmgURL,
      expectedBundleIdentifier: "org.wencrypt.wencrypt",
      workDir: workValid,
      requireCoreLibrary: false
    )
    #expect(extracted.lastPathComponent == "wencrypt.app")
    #expect(fm.fileExists(atPath: extracted.appendingPathComponent("Contents/MacOS/wencrypt").path))
    let remainingMounted = try fm.contentsOfDirectory(atPath: workValid.appendingPathComponent("mounted").path)
    #expect(remainingMounted.isEmpty)

    let workMismatch = root.appendingPathComponent("work-dmg-mismatch", isDirectory: true)
    var rejectedWrongId = false
    do {
      _ = try AppUpdater.extractAndValidateBundle(
        archiveURL: dmgURL,
        expectedBundleIdentifier: "com.example.other",
        workDir: workMismatch,
        requireCoreLibrary: false
      )
    } catch AppUpdaterError.bundleValidationFailed {
      rejectedWrongId = true
    }
    #expect(rejectedWrongId)
  }
}
