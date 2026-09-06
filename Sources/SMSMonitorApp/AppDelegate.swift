import AppKit
import Darwin
import SMSMonitorCore
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, StatusWidgetActions {
  private let configurations: [MonitorConfiguration]
  private var widgetController: StatusWidgetController!
  private var monitorController: MonitorController!
  private var alertNotifier: AlertNotifier!
  private var localAutomationCheckRuntime: LocalAutomationRuntime?
  private var localFindCheckWebView: WKWebView?
  private var currentSnapshot: FleetMonitorSnapshot

  override init() {
    let configurations = LocalModuleConfigurationStore.loadConfigurations(
      fallback: MonitorConfiguration.allModules
    )
    self.configurations = configurations
    self.currentSnapshot = FleetMonitorSnapshot.initial(configurations: configurations)
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    if ProcessInfo.processInfo.environment["SMS_MONITOR_LOCAL_AUTOMATION_CHECK"] == "1" {
      runLocalAutomationCheck()
      return
    }
    alertNotifier = AlertNotifier()
    monitorController = MonitorController(configurations: configurations)
    ApplicationMenu.setFindTarget(self)
    widgetController = StatusWidgetController(
      configurations: configurations,
      sampleLimit: monitorController.sampleLimit
    )

    widgetController.actions = self
    monitorController.onStateChange = { [weak self] snapshot, changedModuleID in
      self?.handle(snapshot: snapshot, changedModuleID: changedModuleID)
    }
    monitorController.onSampleLimitChange = { [weak self] sampleLimit in
      self?.widgetController.updateSampleLimit(sampleLimit)
    }

    widgetController.show()
    monitorController.start()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationWillTerminate(_ notification: Notification) {
    monitorController?.stop()
  }

  func statusWidgetRequestedScan(moduleID: String?) {
    monitorController.scanNow(moduleID: moduleID)
  }

  func statusWidgetRequestedPlatformWindow(moduleID: String?) {
    monitorController.showPlatformWindow(moduleID: moduleID)
  }

  func statusWidgetRequestedMonitoringChange(moduleID: String, enabled: Bool) {
    monitorController.setMonitoringEnabled(enabled, moduleID: moduleID)
  }

  func statusWidgetRequestedMute() {
    alertNotifier.muteForTenMinutes()
    refreshWidget()
  }

  func statusWidgetRequestedQuit() {
    NSApp.terminate(nil)
  }

  @objc func findInCurrentBackend(_ sender: Any?) {
    monitorController?.focusFind()
  }

  private func handle(snapshot: FleetMonitorSnapshot, changedModuleID: String?) {
    currentSnapshot = snapshot

    if let changedModuleID,
      let focus = snapshot.focus,
      focus.configuration.id == changedModuleID,
      case .alert(let metrics, _) = focus.state,
      ProcessInfo.processInfo.environment["SMS_MONITOR_TEST_SCENARIO"] == nil
    {
      alertNotifier.notify(configuration: focus.configuration, metrics: metrics)
    } else if snapshot.alertCount == 0 {
      alertNotifier.clearAlert()
    }

    refreshWidget()
  }

  private func refreshWidget() {
    widgetController.update(
      snapshot: currentSnapshot,
      muteDescription: alertNotifier.muteDescription
    )
  }

  private func runLocalAutomationCheck() {
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
