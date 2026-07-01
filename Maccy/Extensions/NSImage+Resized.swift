import AppKit
import ImageIO

enum ImageDownsampler {
  /// Returns a copy of the image encoded in `data` that fits into `bounds` (in points).
  ///
  /// The result is decoded directly at the target pixel size with ImageIO, so it doesn't keep
  /// the full-size source image alive the way a drawing-handler based `NSImage` would.
  /// Images that already fit are returned as-is. Safe to call off the main thread.
  static func downsample(_ data: Data, toFit bounds: NSSize, scale: CGFloat) -> NSImage? {
    guard let original = NSImage(data: data) else {
      return nil
    }

    let size = original.size
    guard size.width > 0, size.height > 0 else {
      return nil
    }

    let ratio = min(bounds.width / size.width, bounds.height / size.height)
    // Don't attempt to size up.
    guard ratio < 1 else {
      return original
    }

    let targetSize = NSSize(width: size.width * ratio, height: size.height * ratio)
    let maxPixelSize = max(1, Int((max(targetSize.width, targetSize.height) * max(scale, 1)).rounded(.up)))

    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    if let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
       CGImageSourceGetCount(source) > 0 {
      let thumbnailOptions = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
      ] as CFDictionary

      if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, largestImageIndex(in: source), thumbnailOptions) {
        return NSImage(cgImage: cgImage, size: targetSize)
      }
    }

    return original.rasterized(to: targetSize, scale: scale)
  }

  /// Returns the pixel dimensions of the largest image encoded in `data` without decoding it.
  static func pixelSize(of data: Data) -> NSSize? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
          CGImageSourceGetCount(source) > 0,
          let properties = CGImageSourceCopyPropertiesAtIndex(
            source, largestImageIndex(in: source), nil
          ) as? [CFString: Any],
          let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
          let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
      return nil
    }

    // EXIF orientations 5-8 are rotated by 90°, so the displayed image has swapped dimensions.
    let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    if (5...8).contains(orientation) {
      return NSSize(width: height, height: width)
    }
    return NSSize(width: width, height: height)
  }

  private static func largestImageIndex(in source: CGImageSource) -> Int {
    var bestIndex = 0
    var bestPixelCount = 0

    for index in 0..<CGImageSourceGetCount(source) {
      guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
        continue
      }

      if width * height > bestPixelCount {
        bestPixelCount = width * height
        bestIndex = index
      }
    }

    return bestIndex
  }
}

extension NSImage {
  /// Draws the image into a standalone bitmap of the given size, dropping any reference to the source.
  func rasterized(to newSize: NSSize, scale: CGFloat) -> NSImage? {
    let pixelsWide = max(1, Int((newSize.width * max(scale, 1)).rounded()))
    let pixelsHigh = max(1, Int((newSize.height * max(scale, 1)).rounded()))

    guard let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: pixelsWide,
      pixelsHigh: pixelsHigh,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) else {
      return nil
    }
    bitmap.size = newSize

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
      return nil
    }

    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    draw(in: NSRect(origin: .zero, size: newSize), from: .zero, operation: .copy, fraction: 1)
    context.flushGraphics()

    let image = NSImage(size: newSize)
    image.addRepresentation(bitmap)
    return image
  }

  func prominentHue(sampleSize: Int = 32) -> Double? {
    guard sampleSize > 0 else {
      return nil
    }

    guard let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: sampleSize,
      pixelsHigh: sampleSize,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bitmapFormat: [],
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) else {
      return nil
    }

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
      NSGraphicsContext.restoreGraphicsState()
      return nil
    }

    NSGraphicsContext.current = context
    draw(in: NSRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
    NSGraphicsContext.restoreGraphicsState()

    let binCount = 36
    var binWeights = [CGFloat](repeating: 0, count: binCount)

    for x in 0..<sampleSize {
      for y in 0..<sampleSize {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
          continue
        }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        if alpha < 0.30 || saturation < 0.20 || brightness < 0.20 {
          continue
        }

        let index = min(binCount - 1, Int(hue * CGFloat(binCount)))
        let weight = alpha * saturation * (0.4 + brightness * 0.6)
        binWeights[index] += weight
      }
    }

    guard let index = binWeights.indices.max(by: { binWeights[$0] < binWeights[$1] }),
          binWeights[index] > 0 else {
      return nil
    }

    return Double((CGFloat(index) + 0.5) / CGFloat(binCount))
  }
}
