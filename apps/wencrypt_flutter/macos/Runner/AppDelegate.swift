import Cocoa
import FlutterMacOS
import ObjectiveC.runtime

/// Guards against a Flutter 3.50.0 macOS engine bug where
/// `AccessibilityBridgeMac::MacOSEventsFromAXEvent` invokes `-startEditing` on
/// `AXPlatformNodeCocoa` for read-only/disabled `kTextField` semantics nodes
/// (such as `SelectableText`) without checking `isKindOfClass:[FlutterTextField class]`.
enum FlutterAccessibilityGuard {
  private static let installOnce: Void = {
    guard let axNodeClass: AnyClass = NSClassFromString("AXPlatformNodeCocoa") else {
      return
    }
    _ = installNoopStartEditing(on: axNodeClass)
  }()

  static func install() {
    _ = installOnce
  }

  /// Registers a no-op `-startEditing` (`v@:`) on `targetClass` only if it
  /// does not already respond to `startEditing`.
  static func installNoopStartEditing(on targetClass: AnyClass) -> Bool {
    let selector = NSSelectorFromString("startEditing")
    guard !class_respondsToSelector(targetClass, selector) else {
      return false
    }
    let noop: @convention(block) (AnyObject) -> Void = { _ in }
    let imp = imp_implementationWithBlock(noop)
    return class_addMethod(targetClass, selector, imp, "v@:")
  }
}

@main
class AppDelegate: FlutterAppDelegate {
  private var pendingInvite: String?
  private var inviteChannel: FlutterMethodChannel?

  override func applicationWillFinishLaunching(_ notification: Notification) {
    FlutterAccessibilityGuard.install()
    SandboxDataMigrator.migrateIfNeeded()
    super.applicationWillFinishLaunching(notification)
  }

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
