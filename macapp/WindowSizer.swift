import SwiftUI
import AppKit

struct WindowSizer: NSViewRepresentable {
  let size: CGSize

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    DispatchQueue.main.async {
      lock(window: view.window)
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async {
      lock(window: nsView.window)
    }
  }

  private func lock(window: NSWindow?) {
    guard let window else { return }
    window.setContentSize(size)
    window.minSize = size
    window.maxSize = size
    window.styleMask.remove(.resizable)
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = true
    window.standardWindowButton(.closeButton)?.isHidden = false
    window.standardWindowButton(.miniaturizeButton)?.isHidden = false
    window.standardWindowButton(.zoomButton)?.isHidden = false
    window.standardWindowButton(.zoomButton)?.isEnabled = false
  }
}
