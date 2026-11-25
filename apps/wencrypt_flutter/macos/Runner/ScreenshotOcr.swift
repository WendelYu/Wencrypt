import Cocoa
import ImageIO
import Vision

enum ScreenshotOcrError: Error {
  case invalidImage
  case recognitionFailed
}

enum ScreenshotOcr {
  private static let maxImageBytes = 16 * 1024 * 1024

  static func readClipboardImage() -> Data? {
    let pasteboard = NSPasteboard.general
    if let png = pasteboard.data(forType: .png), !png.isEmpty, png.count <= maxImageBytes {
      return png
    }
    if let tiff = pasteboard.data(forType: .tiff),
       !tiff.isEmpty,
       tiff.count <= maxImageBytes * 4,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]),
       !png.isEmpty,
       png.count <= maxImageBytes {
      return png
    }
    if let image = NSImage(pasteboard: pasteboard),
       let tiff = image.tiffRepresentation,
       !tiff.isEmpty,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]),
       !png.isEmpty,
       png.count <= maxImageBytes {
      return png
    }
    return nil
  }

  static func recognizeImage(_ data: Data) throws -> [String: Any] {
    guard !data.isEmpty, data.count <= maxImageBytes else {
      throw ScreenshotOcrError.invalidImage
    }
    let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, sourceOptions as CFDictionary),
          cgImage.width > 0,
          cgImage.height > 0 else {
      throw ScreenshotOcrError.invalidImage
    }

    var orientation: CGImagePropertyOrientation = .up
    if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
       let raw = properties[kCGImagePropertyOrientation] as? UInt32,
       let parsed = CGImagePropertyOrientation(rawValue: raw) {
      orientation = parsed
    }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    // Passwords and usernames should never be rewritten into dictionary words.
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
    request.automaticallyDetectsLanguage = true

    let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
    do {
      try handler.perform([request])
    } catch {
      throw ScreenshotOcrError.recognitionFailed
    }

    struct RawBlock {
      let text: String
      let x: Double
      let y: Double
      let w: Double
      let h: Double
    }

    var rawBlocks: [RawBlock] = []
    for observation in request.results ?? [] {
      guard let candidate = observation.topCandidates(1).first else { continue }
      let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
      if text.isEmpty { continue }
      let box = observation.boundingBox
      let x = min(max(Double(box.origin.x), 0.0), 1.0)
      let w = min(max(Double(box.size.width), 0.0), 1.0 - x)
      let h = min(max(Double(box.size.height), 0.0), 1.0)
      let y = min(max(1.0 - Double(box.origin.y + box.size.height), 0.0), 1.0)
      rawBlocks.append(RawBlock(text: text, x: x, y: y, w: w, h: h))
    }

    rawBlocks.sort { lhs, rhs in
      if lhs.y != rhs.y { return lhs.y < rhs.y }
      return lhs.x < rhs.x
    }

    return [
      "text": rawBlocks.map(\.text).joined(separator: "\n"),
      "blocks": rawBlocks.map { block in
        [
          "text": block.text,
          "x": block.x,
          "y": block.y,
          "w": block.w,
          "h": block.h,
        ] as [String: Any]
      },
    ]
  }
}
