import SwiftUI
import AppKit
import ObjectiveC

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

    // Patch the hosting view so the first click on any button is delivered
    // immediately, without first needing to activate the window.
    if let contentView = window.contentView {
      patchAcceptsFirstMouse(contentView)
    }
  }

  /// Dynamically subclasses `view`'s class to override `acceptsFirstMouse(for:)`.
  private func patchAcceptsFirstMouse(_ view: NSView) {
    let base = type(of: view)
    let patchedName = "XTC_FirstMouse_\(NSStringFromClass(base))"

    if NSClassFromString(patchedName) == nil {
      guard let sub = objc_allocateClassPair(base, patchedName, 0) else { return }
      let sel = #selector(NSView.acceptsFirstMouse(for:))
      let imp = imp_implementationWithBlock({ (_: AnyObject, _: AnyObject?) -> Bool in
        return true
      } as @convention(block) (AnyObject, AnyObject?) -> Bool)
      if let m = class_getInstanceMethod(NSView.self, sel) {
        class_addMethod(sub, sel, imp, method_getTypeEncoding(m))
      }
      objc_registerClassPair(sub)
    }

    if let patched = NSClassFromString(patchedName) {
      object_setClass(view, patched)
    }
  }
}
