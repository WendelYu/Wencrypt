import Foundation

let operation = CommandLine.arguments.dropFirst().first ?? "capabilities"
let allowed = ["capabilities", "createProbe", "unlockProbe", "resetProbe", "unlockProbeNonInteractive"]
guard allowed.contains(operation) else {
    print("Use capabilities, createProbe, unlockProbe or resetProbe")
    exit(2)
}
let output = DeviceProbe(storageURL: ProcessInfo.processInfo.environment["WENCRYPT_PROBE_FILE"].map { URL(fileURLWithPath: $0) }).perform(operation)
let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
if output["status"] as? String == "not_passed" { exit(1) }
