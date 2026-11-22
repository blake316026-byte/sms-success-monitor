import WebKit

@MainActor
enum PlatformPageOperationActivity {
  private static var counts: [ObjectIdentifier: Int] = [:]

  static func begin(_ view: WKWebView) {
    counts[ObjectIdentifier(view), default: 0] += 1
  }

  static func end(_ view: WKWebView) {
    let key = ObjectIdentifier(view)
    if let count = counts[key], count > 1 { counts[key] = count - 1 }
    else { counts[key] = nil }
  }

  static func isInUse(_ view: WKWebView) -> Bool {
    counts[ObjectIdentifier(view), default: 0] > 0
  }
}
