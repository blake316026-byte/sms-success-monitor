import AppKit
import WebKit

@MainActor
final class AuthenticatedPageRecoveryCheck: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  private var page: WKWebView!
  private var urlObservation: NSKeyValueObservation?
  private var phase = 0
  private var navigationCount = 0

  func start() {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController.add(self, name: "smsSessionLifecycle")
    configuration.userContentController.addUserScript(WKUserScript(
      source: SessionLifecycleScript.body, injectionTime: .atDocumentStart, forMainFrameOnly: true
    ))
    page = WKWebView(frame: .zero, configuration: configuration)
    page.navigationDelegate = self
    urlObservation = page.observe(\.url, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async { [weak self] in self?.checkBusinessRoute() }
    }
    page.loadHTMLString("<html><body>Session route fixture</body></html>",
      baseURL: URL(string: "https://session-test.invalid/login")!)
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.finish(false, "WebKit timeout") }
  }

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    navigationCount += 1
    guard phase == 0 else { return }
    phase = 1
    page.callAsyncJavaScript(#"""
      window.__smsMonitorSessionEndDelay = 20;
      localStorage.setItem('lt-user', JSON.stringify({ username: 'fixture-user', token: 'fake-current-token' }));
      history.pushState({}, '', '/dashboard');
      """#, arguments: [:], in: nil, in: .page) { result in
        if case .failure = result { self.finish(false, "same-document login transition") }
      }
  }

  private func checkBusinessRoute() {
    guard page.url?.path == "/dashboard" else { return }
    if phase == 1 {
      phase = 2
      page.callAsyncJavaScript(
        AuthenticatedPageSessionScript.body,
        arguments: ["expectedUsername": "fixture-user"], in: nil, in: .page
      ) { result in
        guard case .success(let raw) = result,
          let payload = raw as? [String: Any], payload["kind"] as? String == "authenticated",
          self.navigationCount == 1
        else { self.finish(false, "same-document authenticated recovery"); return }
        self.page.callAsyncJavaScript(#"""
          history.replaceState({}, '', '/login');
          localStorage.removeItem('lt-user');
          await new Promise((resolve) => setTimeout(resolve, 60));
          localStorage.setItem('lt-user', JSON.stringify({ username: 'fixture-user', token: 'fake-current-token' }));
          history.pushState({}, '', '/dashboard');
          """#, arguments: [:], in: nil, in: .page) { result in
            if case .failure = result { self.finish(false, "logout transition") }
          }
      }
    } else if phase == 2 {
      phase = 3
      page.callAsyncJavaScript(
        AuthenticatedPageSessionScript.body,
        arguments: ["expectedUsername": "fixture-user"], in: nil, in: .page
      ) { result in
        guard case .success(let raw) = result,
          let payload = raw as? [String: Any], payload["kind"] as? String == "signedOut",
          self.navigationCount == 1
        else { self.finish(false, "logout must block recovery"); return }
        self.finish(true, "same-document login recovery and revoked-token blocking")
      }
    }
  }

  private func finish(_ passed: Bool, _ message: String) {
    print("\(passed ? "PASS" : "FAIL"): \(message)")
    exit(passed ? 0 : 1)
  }
}

@main
struct AuthenticatedPageRecoveryWebKitCheck {
  @MainActor static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let check = AuthenticatedPageRecoveryCheck()
    check.start()
    app.run()
  }
}
