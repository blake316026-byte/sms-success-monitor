import AppKit
import SMSMonitorCore

final class AppDelegate: NSObject, NSApplicationDelegate, StatusWidgetActions {
  private let configurations = MonitorConfiguration.allModules
  private var widgetController: StatusWidgetController!
  private var monitorController: MonitorController!
  private var alertNotifier: AlertNotifier!
  private var currentSnapshot = FleetMonitorSnapshot.initial(
    configurations: MonitorConfiguration.allModules
  )

  func applicationDidFinishLaunching(_ notification: Notification) {
    alertNotifier = AlertNotifier()
    widgetController = StatusWidgetController(configurations: configurations)
    monitorController = MonitorController(configurations: configurations)

    widgetController.actions = self
    monitorController.onStateChange = { [weak self] snapshot, changedModuleID in
      self?.handle(snapshot: snapshot, changedModuleID: changedModuleID)
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
}
