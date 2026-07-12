import AppKit
import Darwin
import SMSMonitorCore

final class AppDelegate: NSObject, NSApplicationDelegate, StatusWidgetActions {
  private let configurations = MonitorConfiguration.allModules
  private var widgetController: StatusWidgetController!
  private var monitorController: MonitorController!
  private var alertNotifier: AlertNotifier!
  private var localAutomationCheckRuntime: LocalAutomationRuntime?
  private var currentSnapshot = FleetMonitorSnapshot.initial(
    configurations: MonitorConfiguration.allModules
  )

  func applicationDidFinishLaunching(_ notification: Notification) {
    if ProcessInfo.processInfo.environment["SMS_MONITOR_LOCAL_AUTOMATION_CHECK"] == "1" {
      runLocalAutomationCheck()
      return
    }
    alertNotifier = AlertNotifier()
    monitorController = MonitorController(configurations: configurations)
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

  func statusWidgetRequestedMute() {
    alertNotifier.muteForTenMinutes()
    refreshWidget()
  }

  func statusWidgetRequestedQuit() {
    NSApp.terminate(nil)
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
      credentialStore.profile(for: testModuleID) == testProfile
    else {
      fputs("Local Keychain check failed\n", stderr)
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
            print("Local OCR and TOTP runtime checks passed")
            self?.localAutomationCheckRuntime = nil
            NSApp.terminate(nil)
          }
        }
      }
    }
  }
}
