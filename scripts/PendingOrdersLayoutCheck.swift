import AppKit
import WebKit

struct PlatformPageDescriptor {
  let credentialID: String
  let displayName: String
  let startURL: URL
  let webView: WKWebView
}

@main struct PendingOrdersLayoutCheck {
  static func main() {
    _ = NSApplication.shared
    func showsAlertButton(_ view: NSView) -> Bool {
      if let button = view as? NSButton, button.title.contains("TG 报警") { return true }
      return view.subviews.contains(where: showsAlertButton)
    }
    let controller = PendingOrdersWindowController()
    let hasOrderOnlyControls = controller.window?.contentView.map { !showsAlertButton($0) } == true
    let passed = hasOrderOnlyControls && PendingOrdersWindowController.verifyLayoutAndFiltering()
    print(passed ? "PASS: pending order timestamps, filtering, pagination, native layout and no TG controls" : "FAIL: pending orders layout")
    exit(passed ? 0 : 1)
  }
}
