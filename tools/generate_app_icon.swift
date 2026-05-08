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
      try writeIcns(image: image, to: url)
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

  private func writeIcns(image: CGImage, to url: URL) throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let iconsetURL = tempRoot.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true, attributes: nil)

    let variants: [(name: String, size: Int)] = [
      ("icon_16x16.png", 16),
      ("icon_16x16@2x.png", 32),
      ("icon_32x32.png", 32),
      ("icon_32x32@2x.png", 64),
      ("icon_128x128.png", 128),
      ("icon_128x128@2x.png", 256),
      ("icon_256x256.png", 256),
      ("icon_256x256@2x.png", 512),
      ("icon_512x512.png", 512),
      ("icon_512x512@2x.png", 1024)
    ]

    defer {
      try? fileManager.removeItem(at: tempRoot)
    }

    for variant in variants {
      guard let resized = resize(image: image, to: variant.size) else {
        throw NSError(domain: "IconGenerator", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to resize icon to \(variant.size)"])
      }
      let output = iconsetURL.appendingPathComponent(variant.name)
      try writePNG(resized, to: output)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconsetURL.path, "-o", url.path]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let message = String(data: data, encoding: .utf8) ?? "iconutil failed"
      throw NSError(domain: "IconGenerator", code: 8, userInfo: [NSLocalizedDescriptionKey: message])
    }
  }

  private func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
      throw NSError(domain: "IconGenerator", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG destination"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw NSError(domain: "IconGenerator", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize PNG"])
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
