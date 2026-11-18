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
    super.awakeFromNib()
  }
}
