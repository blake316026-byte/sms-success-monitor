import AppKit
import Foundation
import SMSMonitorCore
import WebKit

private final class ModuleMonitorController: NSObject, WKNavigationDelegate {
  let configuration: MonitorConfiguration
  let webView: WKWebView
  var onStateChange: ((AppMonitorState, Date?) -> Void)?

  private var nextScanTimer: Timer?
  private var nextScanAt: Date?
  private var isScanning = false
  private var lastMetrics: ScanMetrics?
  private var needsImmediateScan = true
  private var mockScenario: String?

  init(configuration: MonitorConfiguration) {
    self.configuration = configuration

    let webConfiguration = WKWebViewConfiguration()
    if let profileIdentifier = configuration.profileIdentifier {
      if #available(macOS 14.0, *) {
        webConfiguration.websiteDataStore = WKWebsiteDataStore(
          forIdentifier: profileIdentifier
        )
      } else {
        webConfiguration.websiteDataStore = .nonPersistent()
      }
    } else {
      webConfiguration.websiteDataStore = .default()
    }
    webConfiguration.preferences.javaScriptCanOpenWindowsAutomatically = false

    self.webView = WKWebView(
      frame: NSRect(x: 0, y: 0, width: 1120, height: 720),
      configuration: webConfiguration
    )

    super.init()
    webView.navigationDelegate = self
  }

  deinit {
    nextScanTimer?.invalidate()
  }

  func start() {
    mockScenario = ProcessInfo.processInfo.environment["SMS_MONITOR_TEST_SCENARIO"]
    if mockScenario != nil {
      emitMockState()
      return
    }

    emit(.starting("正在连接平台"), nextScanAt: nil)
    webView.load(URLRequest(url: configuration.targetURL))
  }

  func scanNow() {
    if mockScenario != nil {
      emitMockState()
      return
    }
    guard !isScanning else { return }
    guard let currentURL = webView.url else {
      emit(.starting("平台页面尚未加载"), nextScanAt: nextScanAt)
      scheduleNextScan(after: 5)
      return
    }

    if requiresAuthentication(currentURL) {
      needsImmediateScan = true
      emit(
        .authenticationRequired("平台登录已失效，请打开对应后台标签完成登录。"),
        nextScanAt: nextScanAt
      )
      scheduleNextScan(after: configuration.scanInterval)
      return
    }

    guard isMonitorOrigin(currentURL) else {
      emit(.starting("正在返回后台入口"), nextScanAt: nextScanAt)
      webView.load(URLRequest(url: configuration.targetURL))
      scheduleNextScan(after: 10)
      return
    }

    isScanning = true
    scheduleNextScan(after: configuration.scanInterval)
    emit(.scanning(lastMetrics), nextScanAt: nextScanAt)

    webView.callAsyncJavaScript(
      ScanScript.body,
      arguments: ["sampleLimit": configuration.sampleLimit],
      in: nil,
      in: .page
    ) { [weak self] result in
      DispatchQueue.main.async {
        self?.finishScan(result)
      }
    }
  }

  func stop() {
    nextScanTimer?.invalidate()
    nextScanTimer = nil
    nextScanAt = nil
    webView.stopLoading()
  }

  private func finishScan(_ result: Result<Any, Error>) {
    isScanning = false

    switch result {
    case .failure(let error):
      emit(
        .error("扫描脚本执行失败：\(error.localizedDescription)", Date()),
        nextScanAt: nextScanAt
      )

    case .success(let rawValue):
      guard let payload = rawValue as? [String: Any], let kind = payload["kind"] as? String else {
        emit(.error("短信记录接口返回了无法识别的数据。", Date()), nextScanAt: nextScanAt)
        return
      }

      switch kind {
      case "ok":
        let statuses = payload["statuses"] as? [String] ?? []
        let metrics = MetricsCalculator.calculate(
          statuses: statuses,
          sampleLimit: configuration.sampleLimit
        )
        guard metrics.sampleCount > 0 else {
          emit(.error("短信记录接口未返回可统计的记录。", Date()), nextScanAt: nextScanAt)
          return
        }

        lastMetrics = metrics
        let scannedAt = Date()
        if metrics.shouldAlert(threshold: configuration.alertThreshold) {
          emit(.alert(metrics, scannedAt), nextScanAt: nextScanAt)
        } else {
          emit(.healthy(metrics, scannedAt), nextScanAt: nextScanAt)
        }

      case "auth":
        needsImmediateScan = true
        let message = payload["message"] as? String ?? "平台登录已失效。"
        emit(.authenticationRequired(message), nextScanAt: nextScanAt)

      default:
        let message = payload["message"] as? String ?? "短信记录接口扫描失败。"
        emit(.error(message, Date()), nextScanAt: nextScanAt)
      }
    }
  }

  private func scheduleNextScan(after delay: TimeInterval) {
    nextScanTimer?.invalidate()
    nextScanAt = Date().addingTimeInterval(delay)
    nextScanTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) {
      [weak self] _ in
      self?.scanNow()
    }
  }

  private func emit(_ state: AppMonitorState, nextScanAt: Date?) {
    onStateChange?(state, nextScanAt)
  }

  private func emitMockState() {
    let scenario = mockScenario?.lowercased() ?? "healthy"
    if scenario == "fleet" {
      if configuration.id == "cg02" {
        emit(.authenticationRequired("等待登录"), nextScanAt: nil)
        return
      }
      if configuration.id == "cg04" {
        emit(.error("连接超时，等待重试。", Date()), nextScanAt: Date().addingTimeInterval(60))
        return
      }
    }

    let mockSuccessCounts: [String: Int] = [
      "bills02-otp": 69,
      "bills": 154,
      "bills3": 82,
      "bills4": 131,
      "cg01": 96,
      "cg03-nine01": 176,
      "bs01": 143,
    ]
    let defaultSuccessCount = scenario == "alert" ? 82 : 154
    let successCount =
      scenario == "fleet"
      ? mockSuccessCounts[configuration.id, default: defaultSuccessCount]
      : defaultSuccessCount
    let statuses =
      Array(repeating: "SUCCESS", count: successCount)
      + Array(repeating: "SENT", count: configuration.sampleLimit - successCount)
    let metrics = MetricsCalculator.calculate(
      statuses: statuses,
      sampleLimit: configuration.sampleLimit
    )
    lastMetrics = metrics
    let state: AppMonitorState =
      metrics.shouldAlert(threshold: configuration.alertThreshold)
      ? .alert(metrics, Date())
      : .healthy(metrics, Date())
    emit(state, nextScanAt: Date().addingTimeInterval(configuration.scanInterval))
  }

  private func requiresAuthentication(_ url: URL) -> Bool {
    ["/login", "/ga-auth", "/unlock-ip"].contains(url.path)
  }

  private func isMonitorOrigin(_ url: URL) -> Bool {
    url.scheme == configuration.targetURL.scheme
      && url.host == configuration.targetURL.host
      && url.port == configuration.targetURL.port
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard let url = webView.url else { return }

    if requiresAuthentication(url) {
      needsImmediateScan = true
      emit(
        .authenticationRequired("请完成平台登录，成功后客户端会自动开始监控。"),
        nextScanAt: nextScanAt
      )
      scheduleNextScan(after: configuration.scanInterval)
      return
    }

    guard isMonitorOrigin(url) else { return }
    guard needsImmediateScan else { return }
    needsImmediateScan = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      self?.scanNow()
    }
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    emit(
      .error("平台页面加载失败：\(error.localizedDescription)", Date()),
      nextScanAt: nextScanAt
    )
    scheduleNextScan(after: configuration.scanInterval)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    emit(.error("平台页面进程已重启，正在恢复。", Date()), nextScanAt: nextScanAt)
    webView.reload()
  }
}

final class MonitorController {
  let configurations: [MonitorConfiguration]
  var onStateChange: ((FleetMonitorSnapshot, String?) -> Void)?

  private let monitors: [ModuleMonitorController]
  private let workspaceController: PlatformWorkspaceController
  private var snapshotsByID: [String: ModuleMonitorSnapshot]
  private var activityToken: NSObjectProtocol?

  init(configurations: [MonitorConfiguration]) {
    self.configurations = configurations

    let monitors = configurations.map(ModuleMonitorController.init(configuration:))
    self.monitors = monitors
    self.workspaceController = PlatformWorkspaceController(
      monitoredPages: monitors.map {
        MonitoredPlatformPage(
          configuration: $0.configuration,
          webView: $0.webView
        )
      }
    )
    self.snapshotsByID = Dictionary(
      uniqueKeysWithValues: configurations.map {
        (
          $0.id,
          ModuleMonitorSnapshot(
            configuration: $0,
            state: .starting("等待连接"),
            nextScanAt: nil
          )
        )
      }
    )

    for monitor in monitors {
      monitor.onStateChange = { [weak self, weak monitor] state, nextScanAt in
        guard let self, let monitor else { return }
        self.handle(
          configuration: monitor.configuration,
          state: state,
          nextScanAt: nextScanAt
        )
      }
    }
  }

  deinit {
    if let activityToken {
      ProcessInfo.processInfo.endActivity(activityToken)
    }
  }

  func start() {
    activityToken = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled],
      reason: "Scan SMS delivery success rates for all configured platforms"
    )

    workspaceController.show(moduleID: configurations.first?.id)
    publish(changedModuleID: nil)
    for monitor in monitors {
      monitor.start()
    }
  }

  func scanNow(moduleID: String? = nil) {
    if let moduleID {
      monitors.first { $0.configuration.id == moduleID }?.scanNow()
      return
    }
    for monitor in monitors {
      monitor.scanNow()
    }
  }

  func showPlatformWindow(moduleID: String? = nil) {
    workspaceController.show(moduleID: moduleID)
  }

  func stop() {
    for monitor in monitors {
      monitor.stop()
    }
    workspaceController.stopAll()
  }

  private func handle(
    configuration: MonitorConfiguration,
    state: AppMonitorState,
    nextScanAt: Date?
  ) {
    snapshotsByID[configuration.id] = ModuleMonitorSnapshot(
      configuration: configuration,
      state: state,
      nextScanAt: nextScanAt
    )
    workspaceController.updateMonitorState(moduleID: configuration.id, state: state)
    publish(changedModuleID: configuration.id)
  }

  private func publish(changedModuleID: String?) {
    let modules = configurations.compactMap { snapshotsByID[$0.id] }
    onStateChange?(FleetMonitorSnapshot(modules: modules), changedModuleID)
  }
}
