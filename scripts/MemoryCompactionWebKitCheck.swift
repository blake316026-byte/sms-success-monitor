import AppKit
import WebKit

@MainActor
final class MemoryCompactionCheck: NSObject, WKNavigationDelegate, WKURLSchemeHandler {
  private var page: WKWebView!
  private var phase = 0
  private var reportRequests = 0

  func start() {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.setURLSchemeHandler(self, forURLScheme: "sms-memory-test")
    page = WKWebView(frame: .zero, configuration: configuration)
    page.navigationDelegate = self
    let snapshot = Data(#"[["fixture-session","fixture-value"]]"#.utf8).base64EncodedString()
    page.loadHTMLString(
      ProductionMemoryPage.compactedPageHTML(sessionStorageBase64: snapshot),
      baseURL: ProductionMemoryPage.compactedPageBaseURL(
        for: URL(string: "sms-memory-test://platform/report#CC=fixture")!
      )
    )
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
      self.finish(false, "WebKit timeout")
    }
  }

  nonisolated func webView(
    _ webView: WKWebView,
    start urlSchemeTask: WKURLSchemeTask
  ) {
    Task { @MainActor in
      guard let url = urlSchemeTask.request.url else {
        urlSchemeTask.didFailWithError(URLError(.badURL))
        return
      }
      if url.path == "/report" {
        reportRequests += 1
      }
      let html = "<html><body id='business'>restored business page</body></html>"
      let response = URLResponse(
        url: url,
        mimeType: "text/html",
        expectedContentLength: html.utf8.count,
        textEncodingName: "utf-8"
      )
      urlSchemeTask.didReceive(response)
      urlSchemeTask.didReceive(Data(html.utf8))
      urlSchemeTask.didFinish()
    }
  }

  nonisolated func webView(
    _ webView: WKWebView,
    stop urlSchemeTask: WKURLSchemeTask
  ) {}

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    if phase == 0 {
      phase = 1
      page.evaluateJavaScript("location.hash + ':' + sessionStorage.getItem('fixture-session')") { value, error in
        guard error == nil, value as? String == "#CC=fixture:fixture-value" else {
          self.finish(false, "production shell lost country/verification context or session storage: \(String(describing: value)) \(String(describing: error))")
          return
        }
        self.page.load(URLRequest(url: URL(string: "sms-memory-test://platform/report#CC=fixture")!))
      }
      return
    }

    page.evaluateJavaScript("document.body.id + ':' + document.body.textContent + ':' + location.hash + ':' + sessionStorage.getItem('fixture-session')") { value, _ in
      let body = value as? String
      self.finish(
        self.reportRequests == 1 && body == "business:restored business page:#CC=fixture:fixture-value",
        "production memory shell preserves session and verification context across a real business-page restoration"
      )
    }
  }

  private func finish(_ passed: Bool, _ message: String) {
    print("\(passed ? "PASS" : "FAIL"): \(message)")
    exit(passed ? 0 : 1)
  }
}

@main
struct MemoryCompactionWebKitCheck {
  @MainActor static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let check = MemoryCompactionCheck()
    check.start()
    app.run()
  }
}
