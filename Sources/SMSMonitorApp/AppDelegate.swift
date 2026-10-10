import AppKit
import Darwin
import SMSMonitorCore
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let configurations: [MonitorConfiguration]
  private var monitorController: MonitorController!
  private var localAutomationCheckRuntime: LocalAutomationRuntime?
  private var localFindCheckWebView: WKWebView?

  override init() {
    let configurations = LocalModuleConfigurationStore.loadConfigurations(
      fallback: MonitorConfiguration.allModules
    )
    self.configurations = configurations
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    if ProcessInfo.processInfo.environment["SMS_MONITOR_LOCAL_AUTOMATION_CHECK"] == "1" {
      runLocalAutomationCheck()
      return
    }
    monitorController = MonitorController(configurations: configurations)
    ApplicationMenu.setFindTarget(self)
    monitorController.start()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    monitorController?.showPlatformWindow()
    return true
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationWillTerminate(_ notification: Notification) {
    monitorController?.stop()
  }

  @objc func findInCurrentBackend(_ sender: Any?) {
    monitorController?.focusFind()
  }

  private func runLocalAutomationCheck() {
    let publicWorkspace = PlatformWorkspaceController(
      sampleLimit: 200, monitoredPages: [], credentialStore: LocalCredentialStore()
    )
    let toolbar = publicWorkspace.window.toolbar!
    let items = publicWorkspace.toolbarAllowedItemIdentifiers(toolbar).map(\.rawValue)
    guard items.contains("SMSMonitorPendingOrders"),
      items.contains("SMSMonitorWithdrawalReviewers"),
      !items.contains("SMSMonitorPlatformSampleLimit")
    else {
      fputs("Public workspace entry points are incorrect\n", stderr)
      exit(1)
    }
    publicWorkspace.window.close()
    guard WithdrawalReviewersWindowController.verifyLayoutAndManualFetch() else {
      fputs("Withdrawal reviewers manual fetch or layout is incorrect\n", stderr)
      exit(1)
    }
    guard PendingOrdersWindowController.verifyLayoutAndFiltering() else {
      fputs("Pending orders layout or filtering is incorrect\n", stderr)
      exit(1)
    }
    let credentialStore = LocalCredentialStore()
    let testModuleID = "__local-automation-self-test__"
    let testProfile = LocalLoginProfile(
      username: "self-test",
      password: "local-only",
      totpSecret: "",
      token: "self-test-token",
      autoLoginEnabled: true
    )
    guard credentialStore.save(testProfile, for: testModuleID),
      LocalCredentialStore().profile(for: testModuleID) == testProfile
    else {
      fputs("Local encrypted credential store check failed\n", stderr)
      exit(1)
    }
    credentialStore.remove(moduleID: testModuleID)

    guard let fixtureURL = Bundle.main.resourceURL?
      .appendingPathComponent("auto-login/fixtures/nRVr.jpg"),
      let data = try? Data(contentsOf: fixtureURL)
    else {
      fputs("Local automation fixture is missing\n", stderr)
      exit(1)
    }

    let runtime = LocalAutomationRuntime()
    localAutomationCheckRuntime = runtime
    runtime.recognize(dataURL: "data:image/jpeg;base64,\(data.base64EncodedString())") {
      [weak self] result in
      switch result {
      case .failure(let error):
        let details = String(reflecting: error)
        fputs("Local OCR check failed: \(details)\n", stderr)
        exit(1)
      case .success(let captcha):
        guard captcha == "nRVr" else {
          fputs("Local OCR check returned \(captcha)\n", stderr)
          exit(1)
        }
        runtime.generateTOTP(
          secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ",
          timestamp: Date(timeIntervalSince1970: 59)
        ) { totpResult in
          guard case .success(let code) = totpResult, code == "287082" else {
            fputs("Local TOTP check failed\n", stderr)
            exit(1)
          }
          runtime.generateTOTP(
            secret: "otpauth://totp/SMSMonitor?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ",
            timestamp: Date(timeIntervalSince1970: 59)
          ) { uriResult in
            guard case .success(let uriCode) = uriResult, uriCode == "287082" else {
              fputs("Local otpauth TOTP check failed\n", stderr)
              exit(1)
            }
            self?.runLocalFindCheck()
          }
        }
      }
    }
  }

  private func runLocalFindCheck() {
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
    localFindCheckWebView = webView
    webView.navigationDelegate = self
    webView.loadHTMLString(
      "<html><body>monitor find check<p>FIND again</p><span>final find</span></body></html>",
      baseURL: nil
    )
  }
}

extension AppDelegate: WKNavigationDelegate {
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard webView === localFindCheckWebView else { return }
    webView.callAsyncJavaScript(
      PageFindScript.body,
      arguments: ["query": "find", "backwards": false, "advance": false],
      in: nil,
      in: .page
    ) { [weak self] result in
      guard case .success(let value) = result,
        let payload = value as? [String: Any], payload["supported"] as? Bool == true,
        (payload["count"] as? NSNumber)?.intValue == 3,
        (payload["active"] as? NSNumber)?.intValue == 1
      else {
        fputs("Local page find highlight check failed\n", stderr)
        exit(1)
      }
      webView.callAsyncJavaScript(
        PageFindScript.body,
        arguments: ["query": "find", "backwards": false, "advance": true],
        in: nil,
        in: .page
      ) { navigationResult in
        guard case .success(let navigationValue) = navigationResult,
          let navigationPayload = navigationValue as? [String: Any],
          (navigationPayload["active"] as? NSNumber)?.intValue == 2
        else {
          fputs("Local page find navigation check failed\n", stderr)
          exit(1)
        }
        self?.runPersistentHighlightCheck(in: webView)
      }
    }
  }

  private func runPersistentHighlightCheck(in webView: WKWebView) {
    webView.callAsyncJavaScript(
      """
      \(PersistentHighlightScript.body)
      const first = globalThis.smsPersistentHighlighter.configure({
        enabled: true,
        terms: ["monitor", "dynamic term"],
        color: "#fff176",
        wholeWords: false
      });
      const paragraph = document.createElement("p");
      paragraph.textContent = "dynamic term";
      document.body.appendChild(paragraph);
      await new Promise((resolve) => setTimeout(resolve, 300));
      const highlight = CSS.highlights.get("sms-monitor-persistent-highlight");
      return { supported: first.supported, initialCount: first.count, finalCount: highlight?.size ?? 0 };
      """,
      arguments: [:],
      in: nil,
      in: .page
    ) { [weak self] result in
      guard case .success(let value) = result,
        let payload = value as? [String: Any],
        payload["supported"] as? Bool == true,
        (payload["initialCount"] as? NSNumber)?.intValue == 1,
        (payload["finalCount"] as? NSNumber)?.intValue == 2
      else {
        fputs("Local persistent highlight check failed\n", stderr)
        exit(1)
      }
      print("Local OCR, TOTP, page find and persistent highlighting checks passed")
      self?.localAutomationCheckRuntime = nil
      self?.localFindCheckWebView = nil
      NSApp.terminate(nil)
    }
  }
}
