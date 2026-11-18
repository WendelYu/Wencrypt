import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private let probe = DeviceProbe()
  private let vaultDevice = DeviceVault()
  private let probeQueue = DispatchQueue(label: "org.wencrypt.p0.device")

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

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
    let browsers = [
      "Chrome": ("com.google.Chrome", "chrome://password-manager/settings"),
      "Edge": ("com.microsoft.edgemac", "edge://settings/autofill/passwords"),
      "Firefox": ("org.mozilla.firefox", "about:logins")
    ]
    let browserChannel = FlutterMethodChannel(name:"org.wencrypt.browser-import", binaryMessenger:flutterViewController.engine.binaryMessenger)
    browserChannel.setMethodCallHandler { call, result in
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
