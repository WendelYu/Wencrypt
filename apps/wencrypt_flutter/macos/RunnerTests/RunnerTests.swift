import Cocoa
import CoreText
import FlutterMacOS
import ImageIO
import ObjectiveC.runtime
import Testing
import UniformTypeIdentifiers
@testable import Wencrypt

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

    let writableApp = root.appendingPathComponent("Wencrypt.app", isDirectory: true)
    #expect(AppUpdater.canAutoInstall(bundleURL: writableApp, isSandboxed: false))
    #expect(!AppUpdater.canAutoInstall(bundleURL: writableApp, isSandboxed: true))
    #expect(!AppUpdater.canAutoInstall(
      bundleURL: URL(fileURLWithPath: "/Volumes/Wencrypt/Wencrypt.app"),
      isSandboxed: false
    ))
    #expect(!AppUpdater.canAutoInstall(
      bundleURL: URL(fileURLWithPath: "/private/var/folders/xx/AppTranslocation/AA/d/Wencrypt.app"),
      isSandboxed: false
    ))
    #expect(
      AppUpdater.resolvedFinalTargetURL(
        currentTargetURL: URL(fileURLWithPath: "/tmp/wencrypt.app"),
        stagedAppName: "Wencrypt.app"
      ).lastPathComponent == "Wencrypt.app"
    )
    #expect(
      AppUpdater.resolvedFinalTargetURL(
        currentTargetURL: URL(fileURLWithPath: "/tmp/MyCustom.app"),
        stagedAppName: "Wencrypt.app"
      ).lastPathComponent == "MyCustom.app"
    )
  }

  @Test func appUpdaterExtractAndValidateBundleChecksBundleIdAndSignature() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("wencrypt-bundle-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    let dummyApp = root.appendingPathComponent("src/Wencrypt.app", isDirectory: true)
    let macOsDir = dummyApp.appendingPathComponent("Contents/MacOS", isDirectory: true)
    try fm.createDirectory(at: macOsDir, withIntermediateDirectories: true)

    let plist: [String: Any] = [
      "CFBundleIdentifier": "org.wencrypt.wencrypt",
      "CFBundleExecutable": "Wencrypt",
      "CFBundlePackageType": "APPL",
      "CFBundleShortVersionString": "0.4.0",
      "CFBundleVersion": "22",
    ]
    let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try plistData.write(to: dummyApp.appendingPathComponent("Contents/Info.plist"))

    let exe = macOsDir.appendingPathComponent("Wencrypt")
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
    let zipURL = root.appendingPathComponent("Wencrypt.zip")
    #expect(run("/usr/bin/ditto", ["-c", "-k", "--keepParent", dummyApp.path, zipURL.path]) == 0)

    let workValid = root.appendingPathComponent("work-valid", isDirectory: true)
    let extracted = try AppUpdater.extractAndValidateBundle(
      archiveURL: zipURL,
      expectedBundleIdentifier: "org.wencrypt.wencrypt",
      workDir: workValid,
      requireCoreLibrary: false
    )
    #expect(extracted.lastPathComponent == "Wencrypt.app")

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
    let dummyApp = staging.appendingPathComponent("Wencrypt.app", isDirectory: true)
    let macOsDir = dummyApp.appendingPathComponent("Contents/MacOS", isDirectory: true)
    try fm.createDirectory(at: macOsDir, withIntermediateDirectories: true)

    let plist: [String: Any] = [
      "CFBundleIdentifier": "org.wencrypt.wencrypt",
      "CFBundleExecutable": "Wencrypt",
      "CFBundlePackageType": "APPL",
      "CFBundleShortVersionString": "0.4.0",
      "CFBundleVersion": "22",
    ]
    let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try plistData.write(to: dummyApp.appendingPathComponent("Contents/Info.plist"))

    let exe = macOsDir.appendingPathComponent("Wencrypt")
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
    let dmgURL = root.appendingPathComponent("Wencrypt-v0.4.0-macos-arm64.dmg")
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
    #expect(extracted.lastPathComponent == "Wencrypt.app")
    #expect(fm.fileExists(atPath: extracted.appendingPathComponent("Contents/MacOS/Wencrypt").path))
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

  @Test func screenshotOcrRecognizesRetinaRegistrationScreenshot() throws {
    let width = 3024
    let height = 1964
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      Issue.record("Failed to allocate CGContext")
      return
    }

    ctx.setFillColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // White centered card.
    let cardRect = CGRect(x: 960, y: 420, width: 1100, height: 1120)
    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    ctx.fill(cardRect)

    let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    let systemFont = CTFontCreateUIFontForLanguage(.system, 32, nil)
      ?? CTFontCreateWithName("HelveticaNeue" as CFString, 32, nil)
    let monoFont = CTFontCreateWithName("Menlo" as CFString, 30, nil)

    func drawLine(_ text: String, x: CGFloat, y: CGFloat, font: CTFont) {
      let attrs: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: black,
      ]
      guard let attr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary) else {
        return
      }
      let line = CTLineCreateWithAttributedString(attr)
      ctx.textMatrix = .identity
      ctx.textPosition = CGPoint(x: x, y: y)
      CTLineDraw(line, ctx)
    }

    drawLine("https://console.deepseek.com/sign_up", x: 180, y: 1860, font: systemFont)
    drawLine("注册 DeepSeek 账号", x: 1030, y: 1420, font: systemFont)
    drawLine("邮箱地址（必填）", x: 1030, y: 1290, font: systemFont)
    drawLine("alice.chen_01@example.com", x: 1030, y: 1210, font: monoFont)
    drawLine("登录密码(8-20位)", x: 1030, y: 1070, font: systemFont)
    drawLine("Abc#9876Xy!09K", x: 1030, y: 990, font: monoFont)

    guard let cgImage = ctx.makeImage() else {
      Issue.record("Failed to materialize CGImage")
      return
    }
    let pngData = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(pngData, UTType.png.identifier as CFString, 1, nil) else {
      Issue.record("Failed to create PNG encoder")
      return
    }
    CGImageDestinationAddImage(dest, cgImage, nil)
    #expect(CGImageDestinationFinalize(dest))

    let (preview, ocr) = try ScreenshotOcr.recognizeAndPreview(pngData as Data)
    #expect(!preview.isEmpty)
    #expect(preview.count < 16 * 1024 * 1024)

    if let previewSource = CGImageSourceCreateWithData(preview as CFData, nil),
       let props = CGImageSourceCopyPropertiesAtIndex(previewSource, 0, nil) as? [CFString: Any],
       let pw = props[kCGImagePropertyPixelWidth] as? Int,
       let ph = props[kCGImagePropertyPixelHeight] as? Int {
      #expect(max(pw, ph) <= 1600)
    } else {
      Issue.record("Preview image missing dimensions")
    }

    let text = ocr["text"] as? String ?? ""
    #expect(text.contains("https://console.deepseek.com/sign_up"))
    #expect(text.contains("alice.chen_01@example.com"))
    #expect(text.contains("Abc#9876Xy!09K"))
  }

  @Test func screenshotOcrWarmUpRunsSafelyOnBackgroundQueue() {
    let group = DispatchGroup()
    let queue = DispatchQueue(label: "org.wencrypt.test.ocr.warmup")
    for _ in 0..<2 {
      group.enter()
      queue.async {
        ScreenshotOcr.warmUpIfNeeded()
        group.leave()
      }
    }
    let result = group.wait(timeout: .now() + 15)
    #expect(result == .success)
  }
}
