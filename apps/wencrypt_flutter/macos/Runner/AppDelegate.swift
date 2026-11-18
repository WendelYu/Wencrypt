import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var pendingInvite: String?
  private var inviteChannel: FlutterMethodChannel?

  func configureInviteChannel(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "org.wencrypt.invite", binaryMessenger: messenger)
    inviteChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "takePending" else { result(FlutterMethodNotImplemented); return }
      let value = self?.pendingInvite
      self?.pendingInvite = nil
      result(value)
    }
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    let remaining = urls.filter { url in
      guard url.scheme == "wencrypt", url.host == "join" else { return true }
      pendingInvite = url.absoluteString
      inviteChannel?.invokeMethod("available", arguments: nil)
      return false
    }
    if !remaining.isEmpty { super.application(application, open: remaining) }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
