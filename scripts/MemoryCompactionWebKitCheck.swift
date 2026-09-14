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
    page.loadHTMLString(
      "<html><body id='shell'></body></html>",
      baseURL: URL(string: "sms-memory-test://platform/.sms-monitor-memory-shell")!
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
      page.load(URLRequest(url: URL(string: "sms-memory-test://platform/report#CC=fixture")!))
      return
    }

    page.evaluateJavaScript("document.body.id + ':' + document.body.textContent") { value, _ in
      let body = value as? String
      self.finish(
        self.reportRequests == 1 && body == "business:restored business page",
        "compacted shell restores a real cross-document business page"
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
