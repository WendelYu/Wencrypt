import Cocoa
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Vision

enum ScreenshotOcrError: Error {
  case invalidImage
  case recognitionFailed
}

enum ScreenshotOcr {
  private static let maxImageBytes = 16 * 1024 * 1024
  private static let maxRawClipboardBytes = 64 * 1024 * 1024
  private static let maxInputDimension = 16384
  private static let maxInputPixels: Int64 = 64 * 1024 * 1024
  private static let maxOcrDimension = 2560
  private static let previewMaxDimension = 1600

  private static let warmUpLock = NSLock()
  private static var didWarmUp = false

  private static func markWarmedUp() -> Bool {
    warmUpLock.lock()
    defer { warmUpLock.unlock() }
    if didWarmUp { return false }
    didWarmUp = true
    return true
  }

  /// Pre-warms Apple Vision's text recognition models off the main thread so
  /// the first real screenshot OCR avoids ~400-700ms model initialization latency.
  static func warmUpIfNeeded() {
    guard markWarmedUp() else { return }
    let width = 160
    let height = 48
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      return
    }

    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let font = CTFontCreateUIFontForLanguage(.system, 22, nil)
      ?? CTFontCreateWithName("HelveticaNeue" as CFString, 22, nil)
    let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    let attrs: [CFString: Any] = [
      kCTFontAttributeName: font,
      kCTForegroundColorAttributeName: black,
    ]
    if let attrStr = CFAttributedStringCreate(nil, "账号Ab1" as CFString, attrs as CFDictionary) {
      let line = CTLineCreateWithAttributedString(attrStr)
      ctx.textMatrix = .identity
      ctx.textPosition = CGPoint(x: 8, y: 14)
      CTLineDraw(line, ctx)
    }

    guard let cgImage = ctx.makeImage() else { return }
    _ = try? performTextRequest(on: cgImage, orientation: .up)
  }

  /// Fast main-thread grab of raw image bytes from NSPasteboard without
  /// triggering slow software TIFF->PNG re-encoding on the UI thread.
  static func readRawClipboardImageData() -> Data? {
    let pasteboard = NSPasteboard.general
    if let png = pasteboard.data(forType: .png), !png.isEmpty, png.count <= maxImageBytes {
      return png
    }
    let jpegType = NSPasteboard.PasteboardType("public.jpeg")
    if let jpeg = pasteboard.data(forType: jpegType), !jpeg.isEmpty, jpeg.count <= maxImageBytes {
      return jpeg
    }
    let heicType = NSPasteboard.PasteboardType("public.heic")
    if let heic = pasteboard.data(forType: heicType), !heic.isEmpty, heic.count <= maxImageBytes {
      return heic
    }
    if let tiff = pasteboard.data(forType: .tiff), !tiff.isEmpty, tiff.count <= maxRawClipboardBytes {
      return tiff
    }
    if let image = NSImage(pasteboard: pasteboard),
       let tiff = image.tiffRepresentation,
       !tiff.isEmpty,
       tiff.count <= maxRawClipboardBytes {
      return tiff
    }
    return nil
  }

  /// Converts raw clipboard image bytes (e.g. uncompressed Retina TIFF) into a
  /// compact transferred image off the main thread.
  static func encodeClipboardImageForTransfer(_ rawData: Data) -> Data? {
    guard !rawData.isEmpty, rawData.count <= maxRawClipboardBytes else {
      return nil
    }
    let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
    if let source = CGImageSourceCreateWithData(rawData as CFData, opts as CFDictionary),
       let uti = CGImageSourceGetType(source) as String?,
       rawData.count <= maxImageBytes,
       uti == UTType.png.identifier || uti == UTType.jpeg.identifier || uti == UTType.heic.identifier {
      return rawData
    }
    if let compact = encodePreviewImage(rawData, maxDimension: 2048, preferPng: false) {
      return compact
    }
    return rawData.count <= maxImageBytes ? rawData : nil
  }

  static func readClipboardImage() -> Data? {
    guard let raw = readRawClipboardImageData() else { return nil }
    return encodeClipboardImageForTransfer(raw)
  }

  static func encodePreviewImage(
    _ data: Data,
    maxDimension: Int = previewMaxDimension,
    preferPng: Bool = false
  ) -> Data? {
    guard !data.isEmpty, data.count <= maxRawClipboardBytes else { return nil }
    let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
      return nil
    }
    let thumbOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: false,
      kCGImageSourceThumbnailMaxPixelSize: maxDimension,
    ]
    guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
      return nil
    }
    if !preferPng, let jpeg = encodeCgImage(thumb, typeIdentifier: UTType.jpeg.identifier, quality: 0.88) {
      return jpeg
    }
    return encodeCgImage(thumb, typeIdentifier: UTType.png.identifier, quality: nil)
  }

  private static func encodeCgImage(
    _ cgImage: CGImage,
    typeIdentifier: String,
    quality: CGFloat?
  ) -> Data? {
    let outData = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(outData, typeIdentifier as CFString, 1, nil) else {
      return nil
    }
    let props: CFDictionary? = quality.map {
      [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary
    }
    CGImageDestinationAddImage(dest, cgImage, props)
    guard CGImageDestinationFinalize(dest), outData.length > 0, outData.length <= maxImageBytes else {
      return nil
    }
    return outData as Data
  }

  private static func decodeForOcr(
    _ data: Data,
    maxBytes: Int
  ) throws -> (cgImage: CGImage, orientation: CGImagePropertyOrientation) {
    guard !data.isEmpty, data.count <= maxBytes else {
      throw ScreenshotOcrError.invalidImage
    }
    let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
      throw ScreenshotOcrError.invalidImage
    }

    var orientation: CGImagePropertyOrientation = .up
    if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
      if let rawOrientation = properties[kCGImagePropertyOrientation] as? UInt32,
         let parsed = CGImagePropertyOrientation(rawValue: rawOrientation) {
        orientation = parsed
      }
      if let propW = properties[kCGImagePropertyPixelWidth] as? Int,
         let propH = properties[kCGImagePropertyPixelHeight] as? Int {
        guard propW > 0,
              propH > 0,
              propW <= maxInputDimension,
              propH <= maxInputDimension,
              Int64(propW) * Int64(propH) <= maxInputPixels else {
          throw ScreenshotOcrError.invalidImage
        }
      }
    }

    guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, sourceOptions as CFDictionary),
          decoded.width > 0,
          decoded.height > 0,
          decoded.width <= maxInputDimension,
          decoded.height <= maxInputDimension,
          Int64(decoded.width) * Int64(decoded.height) <= maxInputPixels else {
      throw ScreenshotOcrError.invalidImage
    }

    let maxDim = max(decoded.width, decoded.height)
    if maxDim <= maxOcrDimension {
      return (decoded, orientation)
    }

    let scale = Double(maxOcrDimension) / Double(maxDim)
    let targetW = max(1, Int((Double(decoded.width) * scale).rounded()))
    let targetH = max(1, Int((Double(decoded.height) * scale).rounded()))
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
      data: nil,
      width: targetW,
      height: targetH,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      return (decoded, orientation)
    }
    ctx.interpolationQuality = .high
    ctx.draw(decoded, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
    guard let scaled = ctx.makeImage() else {
      return (decoded, orientation)
    }
    return (scaled, orientation)
  }

  private static func performTextRequest(
    on cgImage: CGImage,
    orientation: CGImagePropertyOrientation
  ) throws -> [VNRecognizedTextObservation] {
    _ = markWarmedUp()

    let request = VNRecognizeTextRequest()
    if #available(macOS 13.0, *) {
      request.revision = VNRecognizeTextRequestRevision3
      request.automaticallyDetectsLanguage = true
    }
    request.recognitionLevel = .accurate
    // Passwords and usernames should never be rewritten into dictionary words.
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

    let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
    do {
      try handler.perform([request])
    } catch {
      throw ScreenshotOcrError.recognitionFailed
    }
    return request.results ?? []
  }

  private static func recognizeCgImage(
    _ cgImage: CGImage,
    orientation: CGImagePropertyOrientation
  ) throws -> [String: Any] {
    let observations = try performTextRequest(on: cgImage, orientation: orientation)

    struct RawBlock {
      let text: String
      let x: Double
      let y: Double
      let w: Double
      let h: Double
    }

    var rawBlocks: [RawBlock] = []
    for observation in observations {
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

  static func recognizeImage(_ data: Data) throws -> [String: Any] {
    let (cgImage, orientation) = try decodeForOcr(data, maxBytes: maxImageBytes)
    return try recognizeCgImage(cgImage, orientation: orientation)
  }

  /// Single-hop clipboard OCR: decodes once, runs Vision OCR and compact preview
  /// thumbnail encoding concurrently off the main thread.
  static func recognizeAndPreview(_ rawData: Data) throws -> (preview: Data, ocr: [String: Any]) {
    let (cgImage, orientation) = try decodeForOcr(rawData, maxBytes: maxRawClipboardBytes)

    let group = DispatchGroup()
    var previewData: Data?
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      previewData = encodePreviewImage(rawData, maxDimension: previewMaxDimension, preferPng: false)
      group.leave()
    }

    let ocrResult = try recognizeCgImage(cgImage, orientation: orientation)
    group.wait()

    let finalPreview = previewData
      ?? encodeCgImage(cgImage, typeIdentifier: UTType.png.identifier, quality: nil)
      ?? (rawData.count <= maxImageBytes ? rawData : Data())
    guard !finalPreview.isEmpty else {
      throw ScreenshotOcrError.invalidImage
    }
    return (finalPreview, ocrResult)
  }
}
