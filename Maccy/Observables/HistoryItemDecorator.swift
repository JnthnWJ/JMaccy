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

  var shelfNamedColorName: String? {
    guard let color = shelfParsedColorCode else {
      return nil
    }
    return Self.closestNamedColorName(for: color)
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

  private struct NamedColor {
    let name: String
    let red: Double
    let green: Double
    let blue: Double
  }

  private struct LabColor {
    let l: Double
    let a: Double
    let b: Double
  }

  private static let namedColorPalette: [NamedColor] = [
    NamedColor(name: "Alice Blue", red: 0.941176, green: 0.972549, blue: 1.000000),
    NamedColor(name: "Antique White", red: 0.980392, green: 0.921569, blue: 0.843137),
    NamedColor(name: "Aqua", red: 0.000000, green: 1.000000, blue: 1.000000),
    NamedColor(name: "Aquamarine", red: 0.498039, green: 1.000000, blue: 0.831373),
    NamedColor(name: "Azure", red: 0.941176, green: 1.000000, blue: 1.000000),
    NamedColor(name: "Beige", red: 0.960784, green: 0.960784, blue: 0.862745),
    NamedColor(name: "Bisque", red: 1.000000, green: 0.894118, blue: 0.768627),
    NamedColor(name: "Black", red: 0.000000, green: 0.000000, blue: 0.000000),
    NamedColor(name: "Blanched Almond", red: 1.000000, green: 0.921569, blue: 0.803922),
    NamedColor(name: "Blue", red: 0.000000, green: 0.000000, blue: 1.000000),
    NamedColor(name: "Blue Violet", red: 0.541176, green: 0.168627, blue: 0.886275),
    NamedColor(name: "Brown", red: 0.647059, green: 0.164706, blue: 0.164706),
    NamedColor(name: "Burly Wood", red: 0.870588, green: 0.721569, blue: 0.529412),
    NamedColor(name: "Cadet Blue", red: 0.372549, green: 0.619608, blue: 0.627451),
    NamedColor(name: "Chartreuse", red: 0.498039, green: 1.000000, blue: 0.000000),
    NamedColor(name: "Chocolate", red: 0.823529, green: 0.411765, blue: 0.117647),
    NamedColor(name: "Coral", red: 1.000000, green: 0.498039, blue: 0.313725),
    NamedColor(name: "Cornflower Blue", red: 0.392157, green: 0.584314, blue: 0.929412),
    NamedColor(name: "Cornsilk", red: 1.000000, green: 0.972549, blue: 0.862745),
    NamedColor(name: "Crimson", red: 0.862745, green: 0.078431, blue: 0.235294),
    NamedColor(name: "Cyan", red: 0.000000, green: 1.000000, blue: 1.000000),
    NamedColor(name: "Dark Blue", red: 0.000000, green: 0.000000, blue: 0.545098),
    NamedColor(name: "Dark Cyan", red: 0.000000, green: 0.545098, blue: 0.545098),
    NamedColor(name: "Dark Goldenrod", red: 0.721569, green: 0.525490, blue: 0.043137),
    NamedColor(name: "Dark Gray", red: 0.662745, green: 0.662745, blue: 0.662745),
    NamedColor(name: "Dark Green", red: 0.000000, green: 0.392157, blue: 0.000000),
    NamedColor(name: "Dark Grey", red: 0.662745, green: 0.662745, blue: 0.662745),
    NamedColor(name: "Dark Khaki", red: 0.741176, green: 0.717647, blue: 0.419608),
    NamedColor(name: "Dark Magenta", red: 0.545098, green: 0.000000, blue: 0.545098),
    NamedColor(name: "Dark Olive Green", red: 0.333333, green: 0.419608, blue: 0.184314),
    NamedColor(name: "Dark Orange", red: 1.000000, green: 0.549020, blue: 0.000000),
    NamedColor(name: "Dark Orchid", red: 0.600000, green: 0.196078, blue: 0.800000),
    NamedColor(name: "Dark Red", red: 0.545098, green: 0.000000, blue: 0.000000),
    NamedColor(name: "Dark Salmon", red: 0.913725, green: 0.588235, blue: 0.478431),
    NamedColor(name: "Dark Sea Green", red: 0.560784, green: 0.737255, blue: 0.560784),
    NamedColor(name: "Dark Slate Blue", red: 0.282353, green: 0.239216, blue: 0.545098),
    NamedColor(name: "Dark Slate Gray", red: 0.184314, green: 0.309804, blue: 0.309804),
    NamedColor(name: "Dark Slate Grey", red: 0.184314, green: 0.309804, blue: 0.309804),
    NamedColor(name: "Dark Turquoise", red: 0.000000, green: 0.807843, blue: 0.819608),
    NamedColor(name: "Dark Violet", red: 0.580392, green: 0.000000, blue: 0.827451),
    NamedColor(name: "Deep Pink", red: 1.000000, green: 0.078431, blue: 0.576471),
    NamedColor(name: "Deep Sky Blue", red: 0.000000, green: 0.749020, blue: 1.000000),
    NamedColor(name: "Dim Gray", red: 0.411765, green: 0.411765, blue: 0.411765),
    NamedColor(name: "Dim Grey", red: 0.411765, green: 0.411765, blue: 0.411765),
    NamedColor(name: "Dodger Blue", red: 0.117647, green: 0.564706, blue: 1.000000),
    NamedColor(name: "Fire Brick", red: 0.698039, green: 0.133333, blue: 0.133333),
    NamedColor(name: "Floral White", red: 1.000000, green: 0.980392, blue: 0.941176),
    NamedColor(name: "Forest Green", red: 0.133333, green: 0.545098, blue: 0.133333),
    NamedColor(name: "Fuchsia", red: 1.000000, green: 0.000000, blue: 1.000000),
    NamedColor(name: "Gainsboro", red: 0.862745, green: 0.862745, blue: 0.862745),
    NamedColor(name: "Ghost White", red: 0.972549, green: 0.972549, blue: 1.000000),
    NamedColor(name: "Gold", red: 1.000000, green: 0.843137, blue: 0.000000),
    NamedColor(name: "Goldenrod", red: 0.854902, green: 0.647059, blue: 0.125490),
    NamedColor(name: "Gray", red: 0.501961, green: 0.501961, blue: 0.501961),
    NamedColor(name: "Green", red: 0.000000, green: 0.501961, blue: 0.000000),
    NamedColor(name: "Green Yellow", red: 0.678431, green: 1.000000, blue: 0.184314),
    NamedColor(name: "Grey", red: 0.501961, green: 0.501961, blue: 0.501961),
    NamedColor(name: "Honeydew", red: 0.941176, green: 1.000000, blue: 0.941176),
    NamedColor(name: "Hot Pink", red: 1.000000, green: 0.411765, blue: 0.705882),
    NamedColor(name: "Indian Red", red: 0.803922, green: 0.360784, blue: 0.360784),
    NamedColor(name: "Indigo", red: 0.294118, green: 0.000000, blue: 0.509804),
    NamedColor(name: "Ivory", red: 1.000000, green: 1.000000, blue: 0.941176),
    NamedColor(name: "Khaki", red: 0.941176, green: 0.901961, blue: 0.549020),
    NamedColor(name: "Lavender", red: 0.901961, green: 0.901961, blue: 0.980392),
    NamedColor(name: "Lavender Blush", red: 1.000000, green: 0.941176, blue: 0.960784),
    NamedColor(name: "Lawn Green", red: 0.486275, green: 0.988235, blue: 0.000000),
    NamedColor(name: "Lemon Chiffon", red: 1.000000, green: 0.980392, blue: 0.803922),
    NamedColor(name: "Light Blue", red: 0.678431, green: 0.847059, blue: 0.901961),
    NamedColor(name: "Light Coral", red: 0.941176, green: 0.501961, blue: 0.501961),
    NamedColor(name: "Light Cyan", red: 0.878431, green: 1.000000, blue: 1.000000),
    NamedColor(name: "Light Goldenrod Yellow", red: 0.980392, green: 0.980392, blue: 0.823529),
    NamedColor(name: "Light Gray", red: 0.827451, green: 0.827451, blue: 0.827451),
    NamedColor(name: "Light Green", red: 0.564706, green: 0.933333, blue: 0.564706),
    NamedColor(name: "Light Grey", red: 0.827451, green: 0.827451, blue: 0.827451),
    NamedColor(name: "Light Pink", red: 1.000000, green: 0.713725, blue: 0.756863),
    NamedColor(name: "Light Salmon", red: 1.000000, green: 0.627451, blue: 0.478431),
    NamedColor(name: "Light Sea Green", red: 0.125490, green: 0.698039, blue: 0.666667),
    NamedColor(name: "Light Sky Blue", red: 0.529412, green: 0.807843, blue: 0.980392),
    NamedColor(name: "Light Slate Gray", red: 0.466667, green: 0.533333, blue: 0.600000),
    NamedColor(name: "Light Slate Grey", red: 0.466667, green: 0.533333, blue: 0.600000),
    NamedColor(name: "Light Steel Blue", red: 0.690196, green: 0.768627, blue: 0.870588),
    NamedColor(name: "Light Yellow", red: 1.000000, green: 1.000000, blue: 0.878431),
    NamedColor(name: "Lime", red: 0.000000, green: 1.000000, blue: 0.000000),
    NamedColor(name: "Lime Green", red: 0.196078, green: 0.803922, blue: 0.196078),
    NamedColor(name: "Linen", red: 0.980392, green: 0.941176, blue: 0.901961),
    NamedColor(name: "Magenta", red: 1.000000, green: 0.000000, blue: 1.000000),
    NamedColor(name: "Maroon", red: 0.501961, green: 0.000000, blue: 0.000000),
    NamedColor(name: "Medium Aquamarine", red: 0.400000, green: 0.803922, blue: 0.666667),
    NamedColor(name: "Medium Blue", red: 0.000000, green: 0.000000, blue: 0.803922),
    NamedColor(name: "Medium Orchid", red: 0.729412, green: 0.333333, blue: 0.827451),
    NamedColor(name: "Medium Purple", red: 0.576471, green: 0.439216, blue: 0.858824),
    NamedColor(name: "Medium Sea Green", red: 0.235294, green: 0.701961, blue: 0.443137),
    NamedColor(name: "Medium Slate Blue", red: 0.482353, green: 0.407843, blue: 0.933333),
    NamedColor(name: "Medium Spring Green", red: 0.000000, green: 0.980392, blue: 0.603922),
    NamedColor(name: "Medium Turquoise", red: 0.282353, green: 0.819608, blue: 0.800000),
    NamedColor(name: "Medium Violet Red", red: 0.780392, green: 0.082353, blue: 0.521569),
    NamedColor(name: "Midnight Blue", red: 0.098039, green: 0.098039, blue: 0.439216),
    NamedColor(name: "Mint Cream", red: 0.960784, green: 1.000000, blue: 0.980392),
    NamedColor(name: "Misty Rose", red: 1.000000, green: 0.894118, blue: 0.882353),
    NamedColor(name: "Moccasin", red: 1.000000, green: 0.894118, blue: 0.709804),
    NamedColor(name: "Navajo White", red: 1.000000, green: 0.870588, blue: 0.678431),
    NamedColor(name: "Navy", red: 0.000000, green: 0.000000, blue: 0.501961),
    NamedColor(name: "Old Lace", red: 0.992157, green: 0.960784, blue: 0.901961),
    NamedColor(name: "Olive", red: 0.501961, green: 0.501961, blue: 0.000000),
    NamedColor(name: "Olive Drab", red: 0.419608, green: 0.556863, blue: 0.137255),
    NamedColor(name: "Orange", red: 1.000000, green: 0.647059, blue: 0.000000),
    NamedColor(name: "Orange Red", red: 1.000000, green: 0.270588, blue: 0.000000),
    NamedColor(name: "Orchid", red: 0.854902, green: 0.439216, blue: 0.839216),
    NamedColor(name: "Pale Goldenrod", red: 0.933333, green: 0.909804, blue: 0.666667),
    NamedColor(name: "Pale Green", red: 0.596078, green: 0.984314, blue: 0.596078),
    NamedColor(name: "Pale Turquoise", red: 0.686275, green: 0.933333, blue: 0.933333),
    NamedColor(name: "Pale Violet Red", red: 0.858824, green: 0.439216, blue: 0.576471),
    NamedColor(name: "Papaya Whip", red: 1.000000, green: 0.937255, blue: 0.835294),
    NamedColor(name: "Peach Puff", red: 1.000000, green: 0.854902, blue: 0.725490),
    NamedColor(name: "Peru", red: 0.803922, green: 0.521569, blue: 0.247059),
    NamedColor(name: "Pink", red: 1.000000, green: 0.752941, blue: 0.796078),
    NamedColor(name: "Plum", red: 0.866667, green: 0.627451, blue: 0.866667),
    NamedColor(name: "Powder Blue", red: 0.690196, green: 0.878431, blue: 0.901961),
    NamedColor(name: "Purple", red: 0.501961, green: 0.000000, blue: 0.501961),
    NamedColor(name: "Rebecca Purple", red: 0.400000, green: 0.200000, blue: 0.600000),
    NamedColor(name: "Red", red: 1.000000, green: 0.000000, blue: 0.000000),
    NamedColor(name: "Rosy Brown", red: 0.737255, green: 0.560784, blue: 0.560784),
    NamedColor(name: "Royal Blue", red: 0.254902, green: 0.411765, blue: 0.882353),
    NamedColor(name: "Saddle Brown", red: 0.545098, green: 0.270588, blue: 0.074510),
    NamedColor(name: "Salmon", red: 0.980392, green: 0.501961, blue: 0.447059),
    NamedColor(name: "Sandy Brown", red: 0.956863, green: 0.643137, blue: 0.376471),
    NamedColor(name: "Sea Green", red: 0.180392, green: 0.545098, blue: 0.341176),
    NamedColor(name: "Sea Shell", red: 1.000000, green: 0.960784, blue: 0.933333),
    NamedColor(name: "Sienna", red: 0.627451, green: 0.321569, blue: 0.176471),
    NamedColor(name: "Silver", red: 0.752941, green: 0.752941, blue: 0.752941),
    NamedColor(name: "Sky Blue", red: 0.529412, green: 0.807843, blue: 0.921569),
    NamedColor(name: "Slate Blue", red: 0.415686, green: 0.352941, blue: 0.803922),
    NamedColor(name: "Slate Gray", red: 0.439216, green: 0.501961, blue: 0.564706),
    NamedColor(name: "Slate Grey", red: 0.439216, green: 0.501961, blue: 0.564706),
    NamedColor(name: "Snow", red: 1.000000, green: 0.980392, blue: 0.980392),
    NamedColor(name: "Spring Green", red: 0.000000, green: 1.000000, blue: 0.498039),
    NamedColor(name: "Steel Blue", red: 0.274510, green: 0.509804, blue: 0.705882),
    NamedColor(name: "Tan", red: 0.823529, green: 0.705882, blue: 0.549020),
    NamedColor(name: "Teal", red: 0.000000, green: 0.501961, blue: 0.501961),
    NamedColor(name: "Thistle", red: 0.847059, green: 0.749020, blue: 0.847059),
    NamedColor(name: "Tomato", red: 1.000000, green: 0.388235, blue: 0.278431),
    NamedColor(name: "Turquoise", red: 0.250980, green: 0.878431, blue: 0.815686),
    NamedColor(name: "Violet", red: 0.933333, green: 0.509804, blue: 0.933333),
    NamedColor(name: "Wheat", red: 0.960784, green: 0.870588, blue: 0.701961),
    NamedColor(name: "White", red: 1.000000, green: 1.000000, blue: 1.000000),
    NamedColor(name: "White Smoke", red: 0.960784, green: 0.960784, blue: 0.960784),
    NamedColor(name: "Yellow", red: 1.000000, green: 1.000000, blue: 0.000000),
    NamedColor(name: "Yellow Green", red: 0.603922, green: 0.803922, blue: 0.196078),
  ]

  private static let namedColorLabPalette: [(name: String, lab: LabColor)] = namedColorPalette.map { color in
    let lab = labColor(red: color.red, green: color.green, blue: color.blue)
    return (name: color.name, lab: lab)
  }

  private static func closestNamedColorName(for color: NSColor) -> String? {
    guard !namedColorLabPalette.isEmpty else {
      return nil
    }
    guard let blended = opaqueDeviceRGBColor(for: color) else {
      return nil
    }

    let targetLab = labColor(
      red: blended.redComponent,
      green: blended.greenComponent,
      blue: blended.blueComponent
    )

    var closestName: String?
    var bestDistance = Double.greatestFiniteMagnitude

    for candidate in namedColorLabPalette {
      let distance = deltaE76(targetLab, candidate.lab)
      if distance < bestDistance {
        bestDistance = distance
        closestName = candidate.name
      }
    }

    return closestName
  }

  private static func labColor(red: Double, green: Double, blue: Double) -> LabColor {
    let r = srgbToLinear(red)
    let g = srgbToLinear(green)
    let b = srgbToLinear(blue)

    let x = (0.412_456_4 * r) + (0.357_576_1 * g) + (0.180_437_5 * b)
    let y = (0.212_672_9 * r) + (0.715_152_2 * g) + (0.072_175 * b)
    let z = (0.019_333_9 * r) + (0.119_192 * g) + (0.950_304_1 * b)

    let whiteX = 0.950_47
    let whiteY = 1.0
    let whiteZ = 1.088_83

    let fx = labPivot(x / whiteX)
    let fy = labPivot(y / whiteY)
    let fz = labPivot(z / whiteZ)

    return LabColor(
      l: max(0, (116 * fy) - 16),
      a: 500 * (fx - fy),
      b: 200 * (fy - fz)
    )
  }

  private static func deltaE76(_ lhs: LabColor, _ rhs: LabColor) -> Double {
    let dl = lhs.l - rhs.l
    let da = lhs.a - rhs.a
    let db = lhs.b - rhs.b
    return sqrt((dl * dl) + (da * da) + (db * db))
  }

  private static func srgbToLinear(_ component: Double) -> Double {
    let value = clamp(component)
    if value <= 0.040_45 {
      return value / 12.92
    }
    return pow((value + 0.055) / 1.055, 2.4)
  }

  private static func labPivot(_ value: Double) -> Double {
    let epsilon = 216.0 / 24_389.0
    let kappa = 24_389.0 / 27.0
    if value > epsilon {
      return pow(value, 1.0 / 3.0)
    }
    return ((kappa * value) + 16) / 116
  }

  private static func opaqueDeviceRGBColor(for color: NSColor) -> NSColor? {
    guard var rgb = color.usingColorSpace(.deviceRGB) else {
      return nil
    }

    if rgb.alphaComponent < 1,
       let windowBackground = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) {
      let alpha = rgb.alphaComponent
      let red = (rgb.redComponent * alpha) + (windowBackground.redComponent * (1 - alpha))
      let green = (rgb.greenComponent * alpha) + (windowBackground.greenComponent * (1 - alpha))
      let blue = (rgb.blueComponent * alpha) + (windowBackground.blueComponent * (1 - alpha))
      rgb = NSColor(deviceRed: red, green: green, blue: blue, alpha: 1)
    }

    return rgb
  }

  private static func contrastingTextColor(for color: NSColor) -> NSColor {
    guard let rgb = opaqueDeviceRGBColor(for: color) else {
      return .labelColor
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
