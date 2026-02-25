import AppKit

// Based on https://stackoverflow.com/questions/73062803/resizing-nsimage-keeping-aspect-ratio-reducing-the-image-size-while-trying-to-sc.
extension NSImage {
  func resized(to newSize: NSSize) -> NSImage {
    let ratioX = newSize.width / size.width
    let ratioY = newSize.height / size.height
    let ratio = ratioX < ratioY ? ratioX : ratioY
    let newHeight = size.height * ratio
    let newWidth = size.width * ratio
    let newSize = NSSize(width: newWidth, height: newHeight)

    // Don't attempt to size up.
    if newSize.height >= size.height {
      return self
    }

    return NSImage(size: newSize, flipped: false) { destRect in
      if let context = NSGraphicsContext.current {
        context.imageInterpolation = .high
        self.draw(in: destRect, from: NSRect.zero, operation: .copy, fraction: 1)
      }

      return true
    }
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
