import Cocoa
import CryptoKit
import Foundation

/// Non-destructively copies vault database, config files, and Touch ID key
/// metadata from the legacy App Sandbox container into standard
/// `Application Support` once, when migrating to direct-distribution builds.
enum SandboxDataMigrator {
  @discardableResult
  static func migrateIfNeeded(
    legacyContainerRoot: URL? = nil,
    targetAppSupportRoot: URL? = nil,
    isSandboxed: Bool = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
  ) -> Bool {
    guard !isSandboxed else { return false }

    let fm = FileManager.default
    let legacyRoot = legacyContainerRoot ?? fm.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Containers/org.wencrypt.wencrypt/Data/Library/Application Support", isDirectory: true)
    guard let targetRoot = targetAppSupportRoot
      ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else {
      return false
    }

    var migratedAny = false

    let legacyVaultDir = legacyRoot.appendingPathComponent("org.wencrypt.wencrypt", isDirectory: true)
    let legacyDb = legacyVaultDir.appendingPathComponent("wencrypt-alpha.db")
    let targetVaultDir = targetRoot.appendingPathComponent("org.wencrypt.wencrypt", isDirectory: true)
    let targetDb = targetVaultDir.appendingPathComponent("wencrypt-alpha.db")

    if fm.fileExists(atPath: legacyDb.path), !fm.fileExists(atPath: targetDb.path) {
      do {
        try fm.createDirectory(at: targetVaultDir, withIntermediateDirectories: true)
        let items = try fm.contentsOfDirectory(at: legacyVaultDir, includingPropertiesForKeys: nil)
        for source in items {
          let name = source.lastPathComponent
          if name.hasSuffix(".lock") || name.hasSuffix(".tmp") {
            continue
          }
          let dest = targetVaultDir.appendingPathComponent(name)
          if !fm.fileExists(atPath: dest.path) {
            try? fm.copyItem(at: source, to: dest)
          }
        }
        migratedAny = fm.fileExists(atPath: targetDb.path)
      } catch {
        // Leave legacy container intact and let app startup continue.
      }
    }

    let legacyUnlockDir = legacyRoot.appendingPathComponent("org.wencrypt/device-unlock", isDirectory: true)
    let targetUnlockDir = targetRoot.appendingPathComponent("org.wencrypt/device-unlock", isDirectory: true)
    if fm.fileExists(atPath: legacyUnlockDir.path) {
      do {
        let items = try fm.contentsOfDirectory(at: legacyUnlockDir, includingPropertiesForKeys: nil)
        let jsonFiles = items.filter { $0.pathExtension == "json" }
        if !jsonFiles.isEmpty {
          try fm.createDirectory(
            at: targetUnlockDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
          )
          var excluded = URLResourceValues()
          excluded.isExcludedFromBackup = true
          var mutableDir = targetUnlockDir
          try? mutableDir.setResourceValues(excluded)
          for source in jsonFiles {
            let dest = targetUnlockDir.appendingPathComponent(source.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) {
              try? fm.copyItem(at: source, to: dest)
              migratedAny = true
            }
          }
        }
      } catch {
        // Best-effort migration only.
      }
    }

    return migratedAny
  }
}

enum AppUpdaterError: Error {
  case readOnlyInstallLocation
  case invalidArchive
  case checksumMismatch
  case bundleValidationFailed
  case swapLaunchFailed

  var code: String {
    switch self {
    case .readOnlyInstallLocation:
      return "install_location_readonly"
    case .invalidArchive:
      return "invalid_archive"
    case .checksumMismatch:
      return "checksum_mismatch"
    case .bundleValidationFailed:
      return "bundle_validation_failed"
    case .swapLaunchFailed:
      return "install_failed"
    }
  }
}

enum AppUpdater {
  static func isSandboxed() -> Bool {
    ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
  }

  static func canAutoInstall(
    bundleURL: URL = Bundle.main.bundleURL,
    isSandboxed: Bool = isSandboxed()
  ) -> Bool {
    guard !isSandboxed else { return false }
    let standardized = bundleURL.standardizedFileURL
    guard standardized.pathExtension == "app" else { return false }
    let path = standardized.path
    if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
      return false
    }
    let parentDir = standardized.deletingLastPathComponent().path
    return FileManager.default.isWritableFile(atPath: parentDir)
  }

  static func appInfo() -> [String: Any] {
    let info = Bundle.main.infoDictionary
    let version = (info?["CFBundleShortVersionString"] as? String) ?? "0.3.11"
    let buildNumber = (info?["CFBundleVersion"] as? String) ?? "1"
    return [
      "version": version,
      "buildNumber": buildNumber,
      "installPath": Bundle.main.bundleURL.standardizedFileURL.path,
      "canAutoInstall": canAutoInstall(),
      "isSandboxed": isSandboxed(),
      "platform": "macos",
    ]
  }

  static func openDirectory(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
      return false
    }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
    return true
  }

  static func openUrl(_ raw: String) -> Bool {
    guard let url = URL(string: raw), url.scheme?.lowercased() == "https" else {
      return false
    }
    return NSWorkspace.shared.open(url)
  }

  static func sha256Hex(of fileURL: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
      if chunk.isEmpty { break }
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  static func verifyZipSha256(archiveURL: URL, expectedHex: String) throws {
    let normalizedExpected = expectedHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalizedExpected.count == 64 else {
      throw AppUpdaterError.checksumMismatch
    }
    let actual = try sha256Hex(of: archiveURL)
    guard actual == normalizedExpected else {
      throw AppUpdaterError.checksumMismatch
    }
  }

  static func extractAndValidateBundle(
    archiveURL: URL,
    expectedBundleIdentifier: String,
    workDir: URL,
    requireCoreLibrary: Bool = true
  ) throws -> URL {
    let fm = FileManager.default
    let stageDir = workDir.appendingPathComponent("extracted", isDirectory: true)
    try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)

    let ext = archiveURL.pathExtension.lowercased()
    if ext == "dmg" {
      let mountDir = workDir.appendingPathComponent("mounted", isDirectory: true)
      try fm.createDirectory(at: mountDir, withIntermediateDirectories: true)
      let attachStatus = runTool(
        "/usr/bin/hdiutil",
        ["attach", "-nobrowse", "-readonly", "-noverify", "-quiet", "-mountpoint", mountDir.path, archiveURL.path]
      )
      guard attachStatus == 0 else {
        throw AppUpdaterError.invalidArchive
      }
      defer {
        if runTool("/usr/bin/hdiutil", ["detach", mountDir.path, "-quiet"]) != 0 {
          _ = runTool("/usr/bin/hdiutil", ["detach", mountDir.path, "-force", "-quiet"])
        }
      }

      let mountedItems = try fm.contentsOfDirectory(
        at: mountDir,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
      let mountedApps = mountedItems.filter { $0.pathExtension == "app" }
      guard let mountedApp = mountedApps.count == 1
        ? mountedApps.first
        : mountedApps.first(where: { $0.lastPathComponent.lowercased() == "wencrypt.app" })
      else {
        throw AppUpdaterError.bundleValidationFailed
      }
      let copiedApp = stageDir.appendingPathComponent(mountedApp.lastPathComponent, isDirectory: true)
      guard runTool("/usr/bin/ditto", [mountedApp.path, copiedApp.path]) == 0 else {
        throw AppUpdaterError.invalidArchive
      }
    } else if ext == "zip" {
      let dittoStatus = runTool("/usr/bin/ditto", ["-x", "-k", archiveURL.path, stageDir.path])
      guard dittoStatus == 0 else {
        throw AppUpdaterError.invalidArchive
      }
    } else {
      throw AppUpdaterError.invalidArchive
    }

    let topLevel = try fm.contentsOfDirectory(
      at: stageDir,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    let apps = topLevel.filter { $0.pathExtension == "app" && $0.lastPathComponent != "__MACOSX" }
    guard let stagedApp = apps.count == 1
      ? apps.first
      : apps.first(where: { $0.lastPathComponent.lowercased() == "wencrypt.app" })
    else {
      throw AppUpdaterError.bundleValidationFailed
    }

    let plistURL = stagedApp.appendingPathComponent("Contents/Info.plist")
    let plistData = try Data(contentsOf: plistURL)
    guard let plist = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
          let bundleId = plist["CFBundleIdentifier"] as? String,
          bundleId == expectedBundleIdentifier,
          let executableName = plist["CFBundleExecutable"] as? String,
          !executableName.isEmpty
    else {
      throw AppUpdaterError.bundleValidationFailed
    }

    let executableURL = stagedApp.appendingPathComponent("Contents/MacOS/\(executableName)")
    guard fm.isExecutableFile(atPath: executableURL.path) else {
      throw AppUpdaterError.bundleValidationFailed
    }

    if requireCoreLibrary {
      let coreURL = stagedApp.appendingPathComponent("Contents/Frameworks/libwencrypt_core.dylib")
      guard fm.fileExists(atPath: coreURL.path) else {
        throw AppUpdaterError.bundleValidationFailed
      }
    }

    let verifyStatus = runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", stagedApp.path])
    guard verifyStatus == 0 else {
      throw AppUpdaterError.bundleValidationFailed
    }

    return stagedApp
  }

  static func resolvedFinalTargetURL(currentTargetURL: URL, stagedAppName: String) -> URL {
    guard currentTargetURL.lastPathComponent.lowercased() == stagedAppName.lowercased() else {
      return currentTargetURL
    }
    if currentTargetURL.lastPathComponent == stagedAppName {
      return currentTargetURL
    }
    let candidate = currentTargetURL.deletingLastPathComponent()
      .appendingPathComponent(stagedAppName, isDirectory: true)
    if FileManager.default.fileExists(atPath: candidate.path) {
      let currentId = (try? currentTargetURL.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
      let candidateId = (try? candidate.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
      if let currentId, let candidateId, !currentId.isEqual(candidateId) {
        return currentTargetURL
      }
    }
    return candidate
  }

  static func swapScriptContents() -> String {
    return """
    #!/bin/sh
    set -eu
    PID="$1"
    TARGET="$2"
    NEW_APP="$3"
    OLD_APP="$4"
    WORK_DIR="$5"
    FINAL_TARGET="${6:-$TARGET}"

    i=0
    while [ "$i" -lt 40 ]; do
      if ! kill -0 "$PID" 2>/dev/null; then
        break
      fi
      i=$((i + 1))
      sleep 0.5
    done

    if kill -0 "$PID" 2>/dev/null; then
      rm -rf "$NEW_APP" "$WORK_DIR"
      exit 1
    fi

    rm -rf "$OLD_APP"
    mv "$TARGET" "$OLD_APP"
    if ! mv "$NEW_APP" "$FINAL_TARGET"; then
      mv "$OLD_APP" "$TARGET" || true
      rm -rf "$NEW_APP" "$WORK_DIR"
      exit 1
    fi

    rm -rf "$OLD_APP" "$WORK_DIR"
    /usr/bin/open -n "$FINAL_TARGET"
    """
  }

  static func installAndRestart(archivePath: String, expectedSha256: String) throws {
    let targetURL = Bundle.main.bundleURL.standardizedFileURL
    guard canAutoInstall(bundleURL: targetURL) else {
      throw AppUpdaterError.readOnlyInstallLocation
    }

    let archiveURL = URL(fileURLWithPath: archivePath)
    let fm = FileManager.default
    let workDir = fm.temporaryDirectory.appendingPathComponent(
      "wencrypt-updater-\(UUID().uuidString)",
      isDirectory: true
    )
    let pid = ProcessInfo.processInfo.processIdentifier
    let parentDir = targetURL.deletingLastPathComponent()
    let newAppURL = parentDir.appendingPathComponent(".wencrypt-update-new-\(pid).app", isDirectory: true)
    let oldAppURL = parentDir.appendingPathComponent(".wencrypt-update-old-\(pid).app", isDirectory: true)

    do {
      try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
      try verifyZipSha256(archiveURL: archiveURL, expectedHex: expectedSha256)

      let expectedBundleId = Bundle.main.bundleIdentifier ?? "org.wencrypt.wencrypt"
      let stagedApp = try extractAndValidateBundle(
        archiveURL: archiveURL,
        expectedBundleIdentifier: expectedBundleId,
        workDir: workDir,
        requireCoreLibrary: true
      )
      let finalTargetURL = resolvedFinalTargetURL(
        currentTargetURL: targetURL,
        stagedAppName: stagedApp.lastPathComponent
      )

      try? fm.removeItem(at: newAppURL)
      guard runTool("/usr/bin/ditto", [stagedApp.path, newAppURL.path]) == 0 else {
        throw AppUpdaterError.swapLaunchFailed
      }
      _ = runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newAppURL.path])
      try? fm.removeItem(at: archiveURL)

      let scriptURL = workDir.appendingPathComponent("apply-update.sh")
      try swapScriptContents().write(to: scriptURL, atomically: true, encoding: .utf8)
      try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

      let launcher = Process()
      launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
      launcher.arguments = [
        scriptURL.path,
        String(pid),
        targetURL.path,
        newAppURL.path,
        oldAppURL.path,
        workDir.path,
        finalTargetURL.path,
      ]
      launcher.standardInput = FileHandle.nullDevice
      launcher.standardOutput = FileHandle.nullDevice
      launcher.standardError = FileHandle.nullDevice
      try launcher.run()
    } catch {
      try? fm.removeItem(at: newAppURL)
      try? fm.removeItem(at: workDir)
      try? fm.removeItem(at: archiveURL)
      if let updaterError = error as? AppUpdaterError {
        throw updaterError
      }
      throw AppUpdaterError.swapLaunchFailed
    }
  }

  private static func runTool(_ executable: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus
    } catch {
      return -1
    }
  }
}
