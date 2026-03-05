import AppKit.NSColor
import AppKit.NSWorkspace
import Defaults
import Foundation
import Observation
import Sauce
import SwiftUI

@Observable
class HistoryItemDecorator: Identifiable, Hashable, HasVisibility {
  private static let thumbnailCache = NSCache<NSString, NSImage>()
  private static let previewCache = NSCache<NSString, NSImage>()

  enum ShelfCardType {
    case text
    case link
    case image
    case file
    case richText

    var key: String {
      switch self {
      case .text:
        return "shelf_type_text"
      case .link:
        return "shelf_type_link"
      case .image:
        return "shelf_type_image"
      case .file:
        return "shelf_type_file"
      case .richText:
        return "shelf_type_rich_text"
      }
    }
  }

  private static let relativeDateFormatter = RelativeDateTimeFormatter()

  static func == (lhs: HistoryItemDecorator, rhs: HistoryItemDecorator) -> Bool {
    return lhs.id == rhs.id
  }

  static var previewImageSize: NSSize { NSScreen.forPopup?.visibleFrame.size ?? NSSize(width: 2048, height: 1536) }
  static var thumbnailImageSize: NSSize { NSSize(width: 340, height: Defaults[.imageMaxHeight]) }

  var id: UUID { item.id }

  var title: String = ""
  var attributedTitle: AttributedString?

  var isVisible: Bool = true
  var selectionIndex: Int = -1
  var isSelected: Bool {
    return selectionIndex != -1
  }
  var shortcuts: [KeyShortcut] = []

  var application: String? {
    if item.universalClipboard {
      return "iCloud"
    }

    guard let bundle = item.application,
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
    else {
      return nil
    }

    return url.deletingPathExtension().lastPathComponent
  }

  var hasImage: Bool { item.image != nil }

  var previewImageGenerationTask: Task<(), Error>?
  var thumbnailImageGenerationTask: Task<(), Error>?
  var previewImage: NSImage?
  var thumbnailImage: NSImage?
  var applicationImage: ApplicationImage

  // 10k characters seems to be more than enough on large displays
  var text: String { item.previewableText.shortened(to: 10_000) }
  var copyableImageText: String {
    guard hasImage else {
      return ""
    }

    return title.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  var canCopyImageText: Bool { !copyableImageText.isEmpty }

  var isPinned: Bool { item.pin != nil }
  var isUnpinned: Bool { item.pin == nil }
  var isTagged: Bool { item.tag != nil }

  var shelfCardType: ShelfCardType {
    if hasImage {
      return .image
    }
    if !item.fileURLs.isEmpty {
      return .file
    }
    if item.rtfData != nil || item.htmlData != nil {
      return .richText
    }

    let value = item.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if let url = URL(string: value), url.scheme != nil, url.host != nil {
      return .link
    }
    return .text
  }

  var shelfTypeKey: String { shelfCardType.key }

  var shelfRelativeTime: String {
    return Self.relativeDateFormatter.localizedString(for: item.lastCopiedAt, relativeTo: Date())
  }

  var shelfHeaderColor: Color {
    if let tag = item.tag {
      return tag.color.color
    }

    if let iconHue = applicationImage.shelfHeaderHue {
      return Color(hue: iconHue, saturation: 0.84, brightness: 0.95)
    }

    let source = item.application ?? application ?? item.title
    let hash = Self.stableHash(source)
    let hue = Double(hash % 360) / 360.0
    return Color(hue: hue, saturation: 0.84, brightness: 0.95)
  }

  var shelfExcerpt: String {
    if hasImage {
      return ""
    }

    return item.previewableText
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .shortened(to: 220)
  }

  var shelfMetadata: String {
    if let image = item.image {
      return "\(Int(image.size.width)) x \(Int(image.size.height))"
    }
    if !item.fileURLs.isEmpty {
      return item.fileURLs.count == 1 ? "1 file" : "\(item.fileURLs.count) files"
    }

    return "\(item.previewableText.count) characters"
  }

  var shelfContentBackgroundColor: Color? {
    guard let color = shelfParsedColorCode else {
      return nil
    }

    return Color(nsColor: color)
  }

  var shelfContentForegroundColor: Color? {
    guard let color = shelfParsedColorCode else {
      return nil
    }

    return Color(nsColor: Self.contrastingTextColor(for: color))
  }

  func hash(into hasher: inout Hasher) {
    // We need to hash title and attributedTitle, so SwiftUI knows it needs to update the view if they chage
    hasher.combine(id)
    hasher.combine(title)
    hasher.combine(attributedTitle)
  }

  private(set) var item: HistoryItem

  init(_ item: HistoryItem, shortcuts: [KeyShortcut] = []) {
    self.item = item
    self.shortcuts = shortcuts
    self.title = item.title
    self.applicationImage = ApplicationImageCache.shared.getImage(item: item)
    self.thumbnailImage = Self.thumbnailCache.object(forKey: self.cacheKey)
    self.previewImage = Self.previewCache.object(forKey: self.cacheKey)

    synchronizeItemPin()
    synchronizeItemTitle()
  }

  @MainActor
  func ensureThumbnailImage() {
    guard item.image != nil else {
      return
    }
    guard thumbnailImage == nil else {
      return
    }
    guard thumbnailImageGenerationTask == nil else {
      return
    }

    thumbnailImageGenerationTask = Task { @MainActor [weak self] in
      defer {
        self?.thumbnailImageGenerationTask = nil
      }

      self?.generateThumbnailImage()
    }
  }

  @MainActor
  func ensurePreviewImage() {
    guard item.image != nil else {
      return
    }
    guard previewImage == nil else {
      return
    }
    guard previewImageGenerationTask == nil else {
      return
    }

    previewImageGenerationTask = Task { @MainActor [weak self] in
      defer {
        self?.previewImageGenerationTask = nil
      }

      self?.generatePreviewImage()
    }
  }

  @MainActor
  func asyncGetPreviewImage() async -> NSImage? {
    if let image = previewImage {
      return image
    }

    ensurePreviewImage()
    _ = await previewImageGenerationTask?.result
    return previewImage
  }

  @MainActor
  func cleanupImages() {
    thumbnailImageGenerationTask?.cancel()
    previewImageGenerationTask?.cancel()
    thumbnailImageGenerationTask = nil
    previewImageGenerationTask = nil
    Self.thumbnailCache.removeObject(forKey: cacheKey)
    Self.previewCache.removeObject(forKey: cacheKey)
    thumbnailImage?.recache()
    previewImage?.recache()
    thumbnailImage = nil
    previewImage = nil
  }

  @MainActor
  private func generateThumbnailImage() {
    guard let image = item.image else {
      return
    }

    thumbnailImage = image.resized(to: HistoryItemDecorator.thumbnailImageSize)
    if let thumbnailImage {
      Self.thumbnailCache.setObject(thumbnailImage, forKey: cacheKey)
    }
  }

  @MainActor
  private func generatePreviewImage() {
    guard let image = item.image else {
      return
    }

    previewImage = image.resized(to: HistoryItemDecorator.previewImageSize)
    if let previewImage {
      Self.previewCache.setObject(previewImage, forKey: cacheKey)
    }
  }

  @MainActor
  func sizeImages() {
    generatePreviewImage()
    generateThumbnailImage()
  }

  func highlight(_ query: String, _ ranges: [Range<String.Index>]) {
    guard !query.isEmpty, !title.isEmpty else {
      attributedTitle = nil
      return
    }

    var attributedString = AttributedString(title.shortened(to: 500))
    for range in ranges {
      if let lowerBound = AttributedString.Index(range.lowerBound, within: attributedString),
         let upperBound = AttributedString.Index(range.upperBound, within: attributedString) {
        switch Defaults[.highlightMatch] {
        case .bold:
          attributedString[lowerBound..<upperBound].font = .bold(.body)()
        case .italic:
          attributedString[lowerBound..<upperBound].font = .italic(.body)()
        case .underline:
          attributedString[lowerBound..<upperBound].underlineStyle = .single
        default:
          attributedString[lowerBound..<upperBound].backgroundColor = .findHighlightColor
          attributedString[lowerBound..<upperBound].foregroundColor = .black
        }
      }
    }

    attributedTitle = attributedString
  }

  @MainActor
  func togglePin() {
    if item.pin != nil {
      item.pin = nil
    } else {
      let pin = HistoryItem.randomAvailablePin
      item.pin = pin
    }
  }

  private func synchronizeItemPin() {
    _ = withObservationTracking {
      item.pin
    } onChange: {
      DispatchQueue.main.async {
        if let pin = self.item.pin {
          self.shortcuts = KeyShortcut.create(character: pin)
        }
        self.synchronizeItemPin()
      }
    }
  }

  private func synchronizeItemTitle() {
    _ = withObservationTracking {
      item.title
    } onChange: {
      DispatchQueue.main.async {
        self.title = self.item.title
        self.synchronizeItemTitle()
      }
    }
  }

  private static func stableHash(_ value: String) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 1_099_511_628_211
    }
    return hash
  }

  private var cacheKey: NSString {
    return id.uuidString as NSString
  }

  private var supportsShelfColorCode: Bool {
    return !hasImage && item.fileURLs.isEmpty
  }

  private var shelfParsedColorCode: NSColor? {
    guard supportsShelfColorCode else {
      return nil
    }
    return Self.parseColorCode(item.previewableText)
  }

  private struct FunctionArguments {
    var components: [String]
    var alpha: String?
  }

  private static func parseColorCode(_ rawValue: String) -> NSColor? {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.count <= 160 else {
      return nil
    }

    if let color = parseHexColor(value) {
      return color
    }

    guard let openParen = value.firstIndex(of: "("),
          value.hasSuffix(")") else {
      return nil
    }

    let name = value[..<openParen]
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let argumentsStart = value.index(after: openParen)
    let argumentsEnd = value.index(before: value.endIndex)
    let arguments = String(value[argumentsStart..<argumentsEnd])

    switch name {
    case "rgb":
      return parseRGBColor(arguments, alphaRequired: false)
    case "rgba":
      return parseRGBColor(arguments, alphaRequired: true)
    case "hsl":
      return parseHSLColor(arguments, alphaRequired: false)
    case "hsla":
      return parseHSLColor(arguments, alphaRequired: true)
    case "hsv", "hsb":
      return parseHSVColor(arguments, alphaRequired: false)
    case "hsva", "hsba":
      return parseHSVColor(arguments, alphaRequired: true)
    case "hwb":
      return parseHWBColor(arguments)
    case "cmyk":
      return parseCMYKColor(arguments)
    default:
      return nil
    }
  }

  private static func parseHexColor(_ value: String) -> NSColor? {
    let lowercased = value.lowercased()
    let digits: String
    if lowercased.hasPrefix("#") {
      digits = String(lowercased.dropFirst())
    } else if lowercased.hasPrefix("0x") {
      digits = String(lowercased.dropFirst(2))
    } else {
      return nil
    }

    let normalized: String
    switch digits.count {
    case 3:
      normalized = digits.flatMap { [$0, $0] }.map(String.init).joined()
      return parseHexRGBA("\(normalized)ff")
    case 4:
      normalized = digits.flatMap { [$0, $0] }.map(String.init).joined()
      return parseHexRGBA(normalized)
    case 6:
      return parseHexRGBA("\(digits)ff")
    case 8:
      return parseHexRGBA(digits)
    default:
      return nil
    }
  }

  private static func parseHexRGBA(_ value: String) -> NSColor? {
    guard let parsed = UInt64(value, radix: 16) else {
      return nil
    }

    let red = Double((parsed >> 24) & 0xff) / 255
    let green = Double((parsed >> 16) & 0xff) / 255
    let blue = Double((parsed >> 8) & 0xff) / 255
    let alpha = Double(parsed & 0xff) / 255
    return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
  }

  private static func parseRGBColor(_ value: String, alphaRequired: Bool) -> NSColor? {
    var args = parseFunctionArguments(value)
    var alphaToken = args.alpha

    if alphaToken == nil, args.components.count == 4 {
      alphaToken = args.components.removeLast()
    }
    guard args.components.count == 3 else {
      return nil
    }
    guard !alphaRequired || alphaToken != nil else {
      return nil
    }

    guard let red = parseRGBComponent(args.components[0]),
          let green = parseRGBComponent(args.components[1]),
          let blue = parseRGBComponent(args.components[2]) else {
      return nil
    }

    let alpha = alphaToken.flatMap(parseAlpha) ?? 1
    return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
  }

  private static func parseHSLColor(_ value: String, alphaRequired: Bool) -> NSColor? {
    var args = parseFunctionArguments(value)
    var alphaToken = args.alpha

    if alphaToken == nil, args.components.count == 4 {
      alphaToken = args.components.removeLast()
    }
    guard args.components.count == 3 else {
      return nil
    }
    guard !alphaRequired || alphaToken != nil else {
      return nil
    }

    guard let hue = parseHue(args.components[0]),
          let saturation = parseUnitComponent(args.components[1]),
          let lightness = parseUnitComponent(args.components[2]) else {
      return nil
    }

    let rgb = hslToRGB(hue: hue, saturation: saturation, lightness: lightness)
    let alpha = alphaToken.flatMap(parseAlpha) ?? 1
    return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: alpha)
  }

  private static func parseHSVColor(_ value: String, alphaRequired: Bool) -> NSColor? {
    var args = parseFunctionArguments(value)
    var alphaToken = args.alpha

    if alphaToken == nil, args.components.count == 4 {
      alphaToken = args.components.removeLast()
    }
    guard args.components.count == 3 else {
      return nil
    }
    guard !alphaRequired || alphaToken != nil else {
      return nil
    }

    guard let hue = parseHue(args.components[0]),
          let saturation = parseUnitComponent(args.components[1]),
          let brightness = parseUnitComponent(args.components[2]) else {
      return nil
    }

    let alpha = alphaToken.flatMap(parseAlpha) ?? 1
    return NSColor(calibratedHue: hue / 360, saturation: saturation, brightness: brightness, alpha: alpha)
      .usingColorSpace(.deviceRGB)
  }

  private static func parseHWBColor(_ value: String) -> NSColor? {
    var args = parseFunctionArguments(value)
    var alphaToken = args.alpha

    if alphaToken == nil, args.components.count == 4 {
      alphaToken = args.components.removeLast()
    }
    guard args.components.count == 3 else {
      return nil
    }

    guard let hue = parseHue(args.components[0]),
          let whiteness = parseUnitComponent(args.components[1]),
          let blackness = parseUnitComponent(args.components[2]) else {
      return nil
    }

    let alpha = alphaToken.flatMap(parseAlpha) ?? 1
    guard let baseColor = NSColor(calibratedHue: hue / 360, saturation: 1, brightness: 1, alpha: 1)
      .usingColorSpace(.deviceRGB) else {
      return nil
    }

    let scale = max(1, whiteness + blackness)
    let normalizedWhiteness = whiteness / scale
    let normalizedBlackness = blackness / scale
    let tint = 1 - normalizedWhiteness - normalizedBlackness

    let red = (baseColor.redComponent * tint) + normalizedWhiteness
    let green = (baseColor.greenComponent * tint) + normalizedWhiteness
    let blue = (baseColor.blueComponent * tint) + normalizedWhiteness
    return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
  }

  private static func parseCMYKColor(_ value: String) -> NSColor? {
    let args = parseFunctionArguments(value)
    guard args.alpha == nil, args.components.count == 4 else {
      return nil
    }

    guard let cyan = parseUnitComponent(args.components[0]),
          let magenta = parseUnitComponent(args.components[1]),
          let yellow = parseUnitComponent(args.components[2]),
          let black = parseUnitComponent(args.components[3]) else {
      return nil
    }

    let red = (1 - cyan) * (1 - black)
    let green = (1 - magenta) * (1 - black)
    let blue = (1 - yellow) * (1 - black)
    return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
  }

  private static func parseFunctionArguments(_ value: String) -> FunctionArguments {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return FunctionArguments(components: [], alpha: nil)
    }

    if trimmed.contains(",") {
      let components = trimmed
        .split(separator: ",", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      return FunctionArguments(components: components, alpha: nil)
    }

    if let slash = trimmed.firstIndex(of: "/") {
      let colorPart = trimmed[..<slash].trimmingCharacters(in: .whitespacesAndNewlines)
      let alphaPart = trimmed[trimmed.index(after: slash)...].trimmingCharacters(in: .whitespacesAndNewlines)
      let components = colorPart
        .split(whereSeparator: \.isWhitespace)
        .map(String.init)
      return FunctionArguments(
        components: components,
        alpha: alphaPart.isEmpty ? nil : alphaPart
      )
    }

    return FunctionArguments(
      components: trimmed.split(whereSeparator: \.isWhitespace).map(String.init),
      alpha: nil
    )
  }

  private static func parseRGBComponent(_ token: String) -> CGFloat? {
    let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
      return nil
    }

    if value.hasSuffix("%") {
      guard let parsed = Double(value.dropLast()) else {
        return nil
      }
      return CGFloat(clamp(parsed / 100))
    }

    guard let parsed = Double(value) else {
      return nil
    }
    return CGFloat(clamp(parsed / 255))
  }

  private static func parseUnitComponent(_ token: String) -> CGFloat? {
    let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
      return nil
    }

    if value.hasSuffix("%") {
      guard let parsed = Double(value.dropLast()) else {
        return nil
      }
      return CGFloat(clamp(parsed / 100))
    }

    guard let parsed = Double(value) else {
      return nil
    }
    let normalized = parsed > 1 ? parsed / 100 : parsed
    return CGFloat(clamp(normalized))
  }

  private static func parseAlpha(_ token: String) -> CGFloat? {
    return parseUnitComponent(token)
  }

  private static func parseHue(_ token: String) -> CGFloat? {
    let value = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !value.isEmpty else {
      return nil
    }

    let rawHue: Double?
    if value.hasSuffix("deg") {
      rawHue = Double(value.dropLast(3))
    } else if value.hasSuffix("rad") {
      rawHue = Double(value.dropLast(3)).map { $0 * 180 / .pi }
    } else if value.hasSuffix("turn") {
      rawHue = Double(value.dropLast(4)).map { $0 * 360 }
    } else if value.hasSuffix("grad") {
      rawHue = Double(value.dropLast(4)).map { $0 * 0.9 }
    } else {
      rawHue = Double(value)
    }

    guard let rawHue else {
      return nil
    }

    let normalized = rawHue.truncatingRemainder(dividingBy: 360)
    let hue = normalized < 0 ? normalized + 360 : normalized
    return CGFloat(hue)
  }

  private static func hslToRGB(hue: CGFloat, saturation: CGFloat, lightness: CGFloat) -> (
    red: CGFloat,
    green: CGFloat,
    blue: CGFloat
  ) {
    let chroma = (1 - abs((2 * lightness) - 1)) * saturation
    let huePrime = hue / 60
    let x = chroma * (1 - abs(huePrime.truncatingRemainder(dividingBy: 2) - 1))

    let (red1, green1, blue1): (CGFloat, CGFloat, CGFloat)
    switch huePrime {
    case 0..<1:
      (red1, green1, blue1) = (chroma, x, 0)
    case 1..<2:
      (red1, green1, blue1) = (x, chroma, 0)
    case 2..<3:
      (red1, green1, blue1) = (0, chroma, x)
    case 3..<4:
      (red1, green1, blue1) = (0, x, chroma)
    case 4..<5:
      (red1, green1, blue1) = (x, 0, chroma)
    default:
      (red1, green1, blue1) = (chroma, 0, x)
    }

    let match = lightness - (chroma / 2)
    return (
      red: clamp(red1 + match),
      green: clamp(green1 + match),
      blue: clamp(blue1 + match)
    )
  }

  private static func clamp(_ value: CGFloat) -> CGFloat {
    return min(max(value, 0), 1)
  }

  private static func clamp(_ value: Double) -> Double {
    return min(max(value, 0), 1)
  }

  private static func contrastingTextColor(for color: NSColor) -> NSColor {
    guard var rgb = color.usingColorSpace(.deviceRGB) else {
      return .labelColor
    }

    if rgb.alphaComponent < 1,
       let windowBackground = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) {
      let alpha = rgb.alphaComponent
      let red = (rgb.redComponent * alpha) + (windowBackground.redComponent * (1 - alpha))
      let green = (rgb.greenComponent * alpha) + (windowBackground.greenComponent * (1 - alpha))
      let blue = (rgb.blueComponent * alpha) + (windowBackground.blueComponent * (1 - alpha))
      rgb = NSColor(deviceRed: red, green: green, blue: blue, alpha: 1)
    }

    let relativeLuminance = { (channel: CGFloat) -> CGFloat in
      if channel <= 0.039_28 {
        return channel / 12.92
      }
      return pow((channel + 0.055) / 1.055, 2.4)
    }

    let luminance = (0.2126 * relativeLuminance(rgb.redComponent))
      + (0.7152 * relativeLuminance(rgb.greenComponent))
      + (0.0722 * relativeLuminance(rgb.blueComponent))

    let whiteContrast = 1.05 / (luminance + 0.05)
    let blackContrast = (luminance + 0.05) / 0.05
    return blackContrast >= whiteContrast ? .black : .white
  }
}
