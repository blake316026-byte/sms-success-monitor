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
    let passed = PendingOrdersWindowController.verifyLayoutAndFiltering()
    print(passed ? "PASS: pending order timestamps, >20m boundary, stale rows, pagination and native layout" : "FAIL: pending orders layout")
    exit(passed ? 0 : 1)
  }
}
