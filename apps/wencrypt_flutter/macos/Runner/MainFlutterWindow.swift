import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private let probe = DeviceProbe()
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

    super.awakeFromNib()
  }
}
