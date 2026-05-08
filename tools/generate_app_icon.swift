import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct IconGenerator {
  let sourceURL: URL
  let outputURL: URL

  func run() throws {
    guard let sourceImage = loadImage(from: sourceURL) else {
      throw NSError(domain: "IconGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to load source image"])
    }

    let croppedImage = squareCrop(sourceImage) ?? sourceImage
    try write(image: croppedImage, to: outputURL)
  }

  private func loadImage(from url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  private func squareCrop(_ image: CGImage) -> CGImage? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return nil }

    let side = min(width, height)
    let originX = (width - side) / 2
    let originY = (height - side) / 2
    let rect = CGRect(x: originX, y: originY, width: side, height: side).integral
    return image.cropping(to: rect)
  }

  private func write(image: CGImage, to url: URL) throws {
    switch url.pathExtension.lowercased() {
    case "icns":
      let sizes: [Int] = [16, 32, 64, 128, 256, 512, 1024]
      guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString, sizes.count, nil) else {
        throw NSError(domain: "IconGenerator", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create ICNS destination"])
      }

      for size in sizes {
        guard let resized = resize(image: image, to: size) else {
          throw NSError(domain: "IconGenerator", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to resize icon to \(size)"])
        }
        CGImageDestinationAddImage(destination, resized, nil)
      }

      guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "IconGenerator", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize ICNS"])
      }
    case "png":
      guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "IconGenerator", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG destination"])
      }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "IconGenerator", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize PNG"])
      }
    default:
      throw NSError(domain: "IconGenerator", code: 7, userInfo: [NSLocalizedDescriptionKey: "Unsupported output format"])
    }
  }

  private func resize(image: CGImage, to targetSize: Int) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
      data: nil,
      width: targetSize,
      height: targetSize,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    context.draw(image, in: CGRect(x: 0, y: 0, width: targetSize, height: targetSize))
    return context.makeImage()
  }
}

do {
  guard CommandLine.arguments.count >= 3 else {
    fputs("Usage: generate_app_icon.swift <source-image> <output.icns>\n", stderr)
    exit(1)
  }

  let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
  let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
  try IconGenerator(sourceURL: sourceURL, outputURL: outputURL).run()
} catch {
  fputs("Icon generation failed: \(error)\n", stderr)
  exit(1)
}
