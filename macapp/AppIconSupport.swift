import Foundation
import AppKit

enum AppIconSupport {
  static func image() -> NSImage {
    if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
       let image = NSImage(contentsOfFile: path) {
      return image
    }
    if let path = Bundle.main.path(forResource: "AppIcon", ofType: "png"),
       let image = NSImage(contentsOfFile: path) {
      return image
    }
    return NSImage(named: NSImage.applicationIconName) ?? NSImage()
  }

  static func apply() {
    NSApplication.shared.applicationIconImage = image()
  }
}
