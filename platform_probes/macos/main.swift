import Foundation

let operation = CommandLine.arguments.dropFirst().first ?? "capabilities"
let allowed = ["capabilities", "createProbe", "unlockProbe", "resetProbe"]
guard allowed.contains(operation) else {
    print("Use capabilities, createProbe, unlockProbe or resetProbe")
    exit(2)
}
let output = DeviceProbe().perform(operation)
let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
if output["status"] as? String == "not_passed" { exit(1) }
