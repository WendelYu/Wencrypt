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
    let browsers = ["Chrome": ("com.google.Chrome", "chrome://password-manager/settings"),
                    "Edge": ("com.microsoft.edgemac", "edge://wallet/passwords"),
                    "Firefox": ("org.mozilla.firefox", "about:logins")]
    let browserChannel = FlutterMethodChannel(name:"org.wencrypt.browser-import", binaryMessenger:flutterViewController.engine.binaryMessenger)
    browserChannel.setMethodCallHandler { call, result in
      if call.method == "installed" {
        result(browsers.keys.sorted().filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier:browsers[$0]!.0) != nil })
      } else if call.method == "open", let name = call.arguments as? String, let (id, page) = browsers[name],
                let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier:id), let url = URL(string:page) {
        NSWorkspace.shared.open([url],withApplicationAt:app,configuration:NSWorkspace.OpenConfiguration()) { _, error in
          DispatchQueue.main.async { result(error == nil ? nil : FlutterError(code:"browser_open_failed",message:nil,details:nil)) }
        }
      } else { result(FlutterMethodNotImplemented) }
    }

    super.awakeFromNib()
  }
}
