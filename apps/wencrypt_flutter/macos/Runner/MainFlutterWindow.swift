import Cocoa
import FlutterMacOS

private final class WatchDirectoryBookmarks {
  private let key = "WencryptBrowserWatchBookmarks"
  private var active: [String: URL] = [:]

  private var data: [Data] {
    get { UserDefaults.standard.array(forKey: key) as? [Data] ?? [] }
    set { UserDefaults.standard.set(newValue, forKey: key) }
  }

  private func resolve(_ bookmark: Data) throws -> (URL, Bool) {
    var stale = false
    let url = try URL(
      resolvingBookmarkData: bookmark,
      options: [.withSecurityScope, .withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &stale
    )
    return (url, stale)
  }

  func restore() -> [String] {
    stop()
    data = data.map { bookmark in
      guard let (url, stale) = try? resolve(bookmark) else { return bookmark }
      let path = url.standardizedFileURL.path
      guard active[path] == nil, url.startAccessingSecurityScopedResource() else {
        return bookmark
      }
      active[path] = url
      if stale, let refreshed = try? url.bookmarkData(options: [.withSecurityScope]) {
        return refreshed
      }
      return bookmark
    }
    return active.keys.sorted()
  }

  func add(_ url: URL) throws -> String {
    let bookmark = try url.bookmarkData(options: [.withSecurityScope])
    let (resolved, _) = try resolve(bookmark)
    let path = resolved.standardizedFileURL.path
    if active[path] == nil {
      guard resolved.startAccessingSecurityScopedResource() else {
        throw CocoaError(.fileReadNoPermission)
      }
      active[path] = resolved
    }
    let existing = data.filter { saved in
      guard let (savedURL, _) = try? resolve(saved) else { return true }
      return savedURL.standardizedFileURL.path != path
    }
    data = existing + [bookmark]
    return path
  }

  func forget(_ path: String) {
    active.removeValue(forKey: path)?.stopAccessingSecurityScopedResource()
    data = data.filter { bookmark in
      guard let (url, _) = try? resolve(bookmark) else { return true }
      return url.standardizedFileURL.path != path
    }
  }

  func stop() {
    for url in active.values { url.stopAccessingSecurityScopedResource() }
    active.removeAll()
  }

  deinit { stop() }
}

class MainFlutterWindow: NSWindow {
  private let probe = DeviceProbe()
  private let watchBookmarks = WatchDirectoryBookmarks()
  private let vaultDevice = DeviceVault()
  private let probeQueue = DispatchQueue(label: "org.wencrypt.p0.device")

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    (NSApp.delegate as? AppDelegate)?.configureInviteChannel(flutterViewController.engine.binaryMessenger)

    let channel = FlutterMethodChannel(
      name: "org.wencrypt.p0/device",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterMethodNotImplemented); return }
      let method = call.method
      self.probeQueue.async {
        let response = self.probe.perform(method)
        DispatchQueue.main.async { result(response) }
      }
    }

    let deviceChannel = FlutterMethodChannel(name: "org.wencrypt.device/vault", binaryMessenger: flutterViewController.engine.binaryMessenger)
    deviceChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterMethodNotImplemented); return }
      if call.method == "cancel" { self.vaultDevice.cancel(); result(nil); return }
      let generation = self.vaultDevice.currentGeneration
      let args = call.arguments as? [String:Any] ?? [:]
      self.probeQueue.async {
        let response = self.vaultDevice.perform(call.method, args, generation:generation)
        DispatchQueue.main.async { result(response) }
      }
    }

    DistributedNotificationCenter.default().addObserver(forName:NSNotification.Name("com.apple.screenIsLocked"),object:nil,queue:.main) { [weak self] _ in
      self?.vaultDevice.cancel()
      deviceChannel.invokeMethod("systemLocked",arguments:nil)
    }
    NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in
      self?.vaultDevice.cancel()
      deviceChannel.invokeMethod("systemLocked",arguments:nil)
    }
    let imageChannel = FlutterMethodChannel(
      name: "org.wencrypt.entry-image",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    imageChannel.setMethodCallHandler { call, result in
      guard call.method == "copyPng" else { result(FlutterMethodNotImplemented); return }
      guard let png = call.arguments as? FlutterStandardTypedData, !png.data.isEmpty else {
        result(FlutterError(code: "invalid_image", message: nil, details: nil))
        return
      }
      let clipboard = NSPasteboard.general
      clipboard.clearContents()
      result(clipboard.setData(png.data, forType: .png))
    }

    let browsers = [
      "Chrome": ("com.google.Chrome", "chrome://password-manager/settings"),
      "Edge": ("com.microsoft.edgemac", "edge://settings/autofill/passwords"),
      "Firefox": ("org.mozilla.firefox", "about:logins")
    ]
    let browserChannel = FlutterMethodChannel(name:"org.wencrypt.browser-import", binaryMessenger:flutterViewController.engine.binaryMessenger)
    browserChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterMethodNotImplemented); return }
      if call.method == "installed" {
        result(browsers.keys.sorted().filter {
          guard let (id, _) = browsers[$0] else { return false }
          return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
        })
      } else if call.method == "open", let name = call.arguments as? String,
                let (id, address) = browsers[name], let url = URL(string: address) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
          result(FlutterError(code: "browser_open_failed", message: nil, details: nil))
          return
        }
        let workspace = NSWorkspace.shared
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.promptsUserIfNeeded = false
        workspace.open([url], withApplicationAt: app, configuration: configuration) { _, error in
          DispatchQueue.main.async {
            if error == nil {
              result(true)
              return
            }
            workspace.openApplication(at: app, configuration: configuration) { _, fallbackError in
              DispatchQueue.main.async {
                guard fallbackError == nil else {
                  result(FlutterError(code: "browser_open_failed", message: nil, details: nil))
                  return
                }
                guard name == "Chrome" || name == "Edge" else {
                  result(false)
                  return
                }
                // These browsers expose a native tab API. macOS asks for consent
                // before the first Apple Event to each browser.
                let script = NSAppleScript(source: """
                  with timeout of 30 seconds
                    tell application id "\(id)"
                      if (count of windows) is 0 then make new window
                      tell front window to make new tab with properties {URL:"\(address)"}
                      activate
                    end tell
                  end timeout
                  """)
                var scriptError: NSDictionary?
                result(script?.executeAndReturnError(&scriptError) != nil && scriptError == nil)
              }
            }
          }
        }
      } else if call.method == "savedWatchDirs" {
        result(self.watchBookmarks.restore())
      } else if call.method == "chooseWatchDir" {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "记住目录"
        panel.beginSheetModal(for: self) { response in
          guard response == .OK, let url = panel.url else { result(nil); return }
          do { result(try self.watchBookmarks.add(url)) }
          catch { result(FlutterError(code: "watch_dir_permission", message: nil, details: nil)) }
        }
      } else if call.method == "forgetWatchDir", let path = call.arguments as? String {
        self.watchBookmarks.forget(path)
        result(nil)
      } else if call.method == "stopWatchAccess" {
        self.watchBookmarks.stop()
        result(nil)
      } else if call.method == "watchDirs" {
        var dirs: [String] = []
        if let pw = getpwuid(getuid()), let homeDir = pw.pointee.pw_dir {
          let realHome = String(cString: homeDir)
          let downloads = (realHome as NSString).appendingPathComponent("Downloads")
          if FileManager.default.fileExists(atPath: downloads) {
            dirs.append(downloads)
          }
        }
        result(dirs)
      } else { result(FlutterMethodNotImplemented) }
    }

    super.awakeFromNib()
  }
}
