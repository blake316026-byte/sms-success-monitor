import AppKit
import WebKit

@MainActor
final class SessionCheck: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  private var page: WKWebView!
  private var phase = 0
  private var observedLogout = false

  func start() {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController.add(self, name: "smsSessionLifecycle")
    configuration.userContentController.addUserScript(WKUserScript(
      source: SessionLifecycleScript.body, injectionTime: .atDocumentStart, forMainFrameOnly: true
    ))
    page = WKWebView(frame: .zero, configuration: configuration)
    page.navigationDelegate = self
    load(path: "/dashboard")
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.finish(false, "WebKit timeout") }
  }

  private func load(path: String) {
    page.loadHTMLString("<html><body>Local session regression fixture</body></html>", baseURL: URL(string: "https://session-test.invalid\(path)")!)
  }

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    if let value = message.body as? [String: Any], value["event"] as? String == "ended" {
      observedLogout = value["username"] as? String == "fixture-user" && value["token"] == nil
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    if phase == 0 {
      phase = 1
      page.callAsyncJavaScript(#"""
        window.__smsMonitorSessionEndDelay = 20;
        const original = JSON.stringify({ username: 'fixture-user', token: 'fake-old-token' });
        localStorage.setItem('lt-user', original);
        localStorage.removeItem('lt-user');
        localStorage.setItem('lt-user', original);
        await new Promise((resolve) => setTimeout(resolve, 40));
        return localStorage.getItem('lt-user') === original
          && localStorage.getItem('__smsMonitorSignedOut') === null;
        """#, arguments: [:], in: nil, in: .page) { result in
          guard (try? result.get()) as? Bool == true else { self.finish(false, "temporary token rotation"); return }
          self.load(path: "/ga-auth")
        }
    } else if phase == 1 {
      phase = 2
      page.callAsyncJavaScript(#"""
        window.__smsMonitorSessionEndDelay = 20;
        const original = localStorage.getItem('lt-user');
        localStorage.removeItem('lt-user');
        await new Promise((resolve) => setTimeout(resolve, 40));
        const stillActive = localStorage.getItem('__smsMonitorSignedOut') === null;
        localStorage.setItem('lt-user', original);
        return stillActive;
        """#, arguments: [:], in: nil, in: .page) { result in
          guard (try? result.get()) as? Bool == true else { self.finish(false, "ga-auth token transition"); return }
          self.load(path: "/login")
        }
    } else if phase == 2 {
      phase = 3
      page.callAsyncJavaScript(#"""
        window.__smsMonitorSessionEndDelay = 20;
        const original = localStorage.getItem('lt-user');
        localStorage.removeItem('lt-user');
        await new Promise((resolve) => setTimeout(resolve, 40));
        const signedOut = localStorage.getItem('__smsMonitorSignedOut') === '1';
        localStorage.setItem('lt-user', original);
        const staleBlocked = localStorage.getItem('lt-user') === null;
        localStorage.setItem('lt-user', JSON.stringify({ username: 'fixture-user', token: 'fake-new-token' }));
        const freshAllowed = localStorage.getItem('__smsMonitorSignedOut') === null;
        localStorage.clear();
        await new Promise((resolve) => setTimeout(resolve, 40));
        return signedOut && staleBlocked && freshAllowed
          && localStorage.getItem('__smsMonitorSignedOut') === '1';
        """#, arguments: [:], in: nil, in: .page) { result in
          guard (try? result.get()) as? Bool == true else { self.finish(false, "logout/late response/fresh session"); return }
          self.load(path: "/login")
        }
    } else {
      let code = """
        let requests = 0;
        window.fetch = async () => { requests++; throw new Error('unexpected query'); };
        const fallbackToken = 'fake-old-token', sampleLimit = 20, platformID = 'fixture', platformName = 'fixture';
        const sms = await (async () => { \(ScanScript.body) })();
        const finance = await (async () => { \(FinanceScript.body) })();
        return requests === 0 && sms.kind === 'auth' && sms.manualOnly
          && finance.kind === 'auth' && finance.manualOnly
          && localStorage.getItem('__smsMonitorSignedOutUsername') === 'fixture-user';
        """
      page.callAsyncJavaScript(code, arguments: [:], in: nil, in: .page) { result in
        self.finish((try? result.get()) as? Bool == true && self.observedLogout,
          "native WebKit logout, reload, stale-token rejection, zero SMS/finance requests")
      }
    }
  }

  private func finish(_ passed: Bool, _ message: String) {
    print("\(passed ? "PASS" : "FAIL"): \(message)")
    exit(passed ? 0 : 1)
  }
}

@main
struct SessionLifecycleWebKitCheck {
  @MainActor static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let check = SessionCheck()
    check.start()
    app.run()
  }
}
