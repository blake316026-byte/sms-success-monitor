import AppKit
import Foundation
import SMSMonitorCore
import WebKit

private final class SessionLifecycleHandler: NSObject, WKScriptMessageHandler {
  weak var owner: ModuleMonitorController?
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    owner?.handleSessionLifecycle(message)
  }
}

private final class ModuleMonitorController: NSObject, WKNavigationDelegate {
  private(set) var configuration: MonitorConfiguration
  let webView: WKWebView
  var onStateChange: ((AppMonitorState, Date?) -> Void)?

  private static let autoLoginCooldown: TimeInterval = 5 * 60
  private static let maximumScanDuration: TimeInterval = 3 * 60
  private static let financialRefreshInterval: TimeInterval = 20

  private let credentialStore: LocalCredentialStore
  private let automationRuntime: LocalAutomationRuntime
  private let loginAutomation: LoginPageAutomation
  private var platformIdentified = false
  private var platformDetectionInProgress = false
  private var browserOnlyPage = false
  private var tianchengLogin: TianchengLoginController?
  private var authenticationDetectionWorkItem: DispatchWorkItem?
  private var nextScanWorkItem: DispatchWorkItem?
  private var startupWorkItem: DispatchWorkItem?
  private var startupID: UUID?
  private var connectionKickoffWorkItem: DispatchWorkItem?
  private var connectionKickoffDeadline: Date?
  private var scanTimeoutWorkItem: DispatchWorkItem?
  private var financialRefreshWorkItem: DispatchWorkItem?
  private var nextScanAt: Date?
  private var isScanning = false
  private var isRefreshingFinancial = false
  private var smsPermissionBlocked = false
  private var financePermissionBlocked = false
  private var activeScanID: UUID?
  private var scanStartedAt: Date?
  private var sampleLimit: Int
  private var lastMetrics: ScanMetrics?
  private var lastMetricsScannedAt: Date?
  private(set) var latestDailyFinancialMetrics: DailyFinancialMetrics?
  private var latestEmittedState: AppMonitorState?
  private var needsImmediateScan = true
  private var apiAuthenticationValidationAttempted = false
  private var consecutiveScanFailures = 0
  private var captchaAutoLoginAttempts = 0
  private var totpAutoLoginAttempts = 0
  private var autoLoginInProgress = false
  private var autoLoginStage = ""
  private var autoLoginCooldownUntil: Date?
  private var autoLoginOutcomeWorkItem: DispatchWorkItem?
  private var loginCompletionDeadline: Date?
  private var manualAuthenticationRequired = false
  private var credentialLoginPending = false
  private var accountIdentityRecoveryPending = false
  private var accountIdentityConflict = false
  private var accountIdentityCheckInProgress = false
  private var accountIdentityCheckAttempts = 0
  private var authenticationEpoch = UUID()
  private let sessionLifecycleHandler = SessionLifecycleHandler()
  private var mockScenario: String?
  private var isStarted = false
  private var monitoringEnabled = false
  private var isPageActive = false
  private var inactiveSince: Date?
  private var lastPageRecycleAt: Date?

  init(
    configuration: MonitorConfiguration,
    sampleLimit: Int,
    credentialStore: LocalCredentialStore,
    automationRuntime: LocalAutomationRuntime,
    loginAutomation: LoginPageAutomation,
    webView existingWebView: WKWebView? = nil
  ) {
    self.configuration = configuration
    self.sampleLimit = SampleLimitPolicy.normalize(sampleLimit)
    self.credentialStore = credentialStore
    self.automationRuntime = automationRuntime
    self.loginAutomation = loginAutomation

    if let existingWebView {
      self.webView = existingWebView
    } else {
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
    }

    super.init()
    webView.navigationDelegate = self
    sessionLifecycleHandler.owner = self
    let content = webView.configuration.userContentController
    content.add(sessionLifecycleHandler, name: "smsSessionLifecycle")
    content.addUserScript(WKUserScript(source: SessionLifecycleScript.body, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    webView.evaluateJavaScript(SessionLifecycleScript.body, completionHandler: nil)
  }

  deinit {
    nextScanWorkItem?.cancel()
    startupWorkItem?.cancel()
    connectionKickoffWorkItem?.cancel()
    scanTimeoutWorkItem?.cancel()
    financialRefreshWorkItem?.cancel()
    autoLoginOutcomeWorkItem?.cancel()
    tianchengLogin?.stop()
  }

  func start(after delay: TimeInterval = 0) {
    monitoringEnabled = true
    isStarted = true
    mockScenario = ProcessInfo.processInfo.environment["SMS_MONITOR_TEST_SCENARIO"]
    if mockScenario != nil {
      emitMockState()
      return
    }

    let safeDelay = max(0, delay)
    if safeDelay > 0 {
      emit(.starting("已错峰排队，监控将在 \(Int(ceil(safeDelay))) 秒内启动"), nextScanAt: nil)
      let startupID = UUID()
      self.startupID = startupID
      let item = DispatchWorkItem { [weak self] in
        guard let self, self.isStarted, self.startupID == startupID else { return }
        self.startupID = nil
        self.startupWorkItem = nil
        self.beginConnection()
      }
      startupWorkItem = item
      DispatchQueue.main.asyncAfter(deadline: .now() + safeDelay, execute: item)
      return
    }
    startupID = nil
    beginConnection()
  }

  private func expediteStartupIfNeeded() {
    guard isStarted, monitoringEnabled, startupID != nil else { return }
    startupID = nil
    startupWorkItem?.cancel()
    startupWorkItem = nil
    NSLog("[SMSMonitor] %@ startup expedited for active page", configuration.id)
    beginConnection()
  }

  private func beginConnection() {
    emit(.starting("正在连接平台"), nextScanAt: nil)
    scheduleFinancialRefresh(after: Self.financialRefreshInterval)
    guard webView.url != nil else {
      webView.load(URLRequest(url: configuration.targetURL))
      scheduleConnectionKickoff()
      return
    }
    scheduleConnectionKickoff(after: 0)
  }

  func startAuthenticationOnly() {
    guard !monitoringEnabled else { return }
    isStarted = true
    mockScenario = nil
    NSLog(
      "[SMSMonitor] %@ starting authentication-only mode at %@",
      configuration.id, webView.url?.path ?? "<unloaded>"
    )
    scheduleAuthenticationOnlyDetection()
    if webView.url == nil {
      webView.load(URLRequest(url: configuration.targetURL))
      return
    }
    if let url = webView.url, requiresAuthentication(url) {
      resumeAuthenticationOnlyIfNeeded()
      return
    }
    identifyPlatform { [weak self] in self?.resumeAuthenticationOnlyIfNeeded() }
  }

  func stopAuthenticationOnly() {
    guard isStarted, !monitoringEnabled else { return }
    isStarted = false
    authenticationDetectionWorkItem?.cancel()
    authenticationDetectionWorkItem = nil
    platformDetectionInProgress = false
    tianchengLogin?.stop()
  }

  func setPageActive(_ active: Bool) {
    if active {
      expediteStartupIfNeeded()
    }
    guard isPageActive != active else { return }
    isPageActive = active
    if active {
      inactiveSince = nil
      guard isStarted, monitoringEnabled, platformIdentified, !browserOnlyPage,
        tianchengLogin == nil,
        let currentURL = webView.url, requiresAuthentication(currentURL)
      else { return }
      if manualAuthenticationRequired && !accountIdentityConflict {
        accountIdentityRecoveryPending = true
        accountIdentityCheckAttempts = 0
      }
      handleAuthenticationRequired("平台需要重新登录。")
    } else {
      inactiveSince = Date()
    }
  }

  func scanNow() {
    if mockScenario != nil {
      emitMockState()
      return
    }
    guard isStarted, monitoringEnabled, !browserOnlyPage, !isScanning,
      !smsPermissionBlocked,
      !autoLoginInProgress
    else { return }
    if !platformIdentified || tianchengLogin != nil {
      identifyPlatform { [weak self] in self?.scanNow() }
      return
    }
    guard !manualAuthenticationRequired else { return }
    guard let currentURL = webView.url else {
      emit(.starting("平台页面尚未加载"), nextScanAt: nextScanAt)
      scheduleNextScan(after: 5)
      return
    }

    if requiresInteractiveAuthentication(currentURL) {
      handleAuthenticationRequired("平台登录已失效。")
      return
    }

    guard isMonitorOrigin(currentURL) else {
      emit(.starting("正在返回后台入口"), nextScanAt: nextScanAt)
      webView.load(URLRequest(url: configuration.targetURL))
      scheduleNextScan(after: 10)
      return
    }

    if credentialLoginPending {
      confirmAutoLoginCompletion()
      return
    }
    if webView.isLoading || currentURL.path.isEmpty || currentURL.path == "/" {
      scheduleNextScan(after: 2)
      return
    }

    cancelNextScan()
    isScanning = true
    let scanID = UUID()
    activeScanID = scanID
    scanStartedAt = Date()
    let activeSampleLimit = sampleLimit
    scheduleScanTimeout(for: scanID)
    emit(.scanning(lastMetrics, lastMetricsScannedAt), nextScanAt: nil)
    NSLog("[SMSMonitor] %@ scan started at %@", configuration.id, currentURL.absoluteString)

    webView.callAsyncJavaScript(
      ScanScript.body,
      arguments: [
        "sampleLimit": activeSampleLimit,
        "fallbackToken": credentialStore.profile(for: configuration.id)?.token ?? "",
      ],
      in: nil,
      in: .page
    ) { [weak self] result in
      DispatchQueue.main.async {
        self?.finishScan(result, sampleLimit: activeSampleLimit, scanID: scanID)
      }
    }
  }

  func updateSampleLimit(_ value: Int) {
    let normalized = SampleLimitPolicy.normalize(value)
    guard normalized != sampleLimit else { return }
    sampleLimit = normalized
    lastMetrics = nil
    lastMetricsScannedAt = nil
    latestDailyFinancialMetrics = nil
    guard !browserOnlyPage else {
      emitBrowserOnlyState()
      return
    }
    needsImmediateScan = true
    emit(.starting("样本已改为 \(normalized) 条，正在重新扫描"), nextScanAt: nil)
    if !isScanning {
      scanNow()
    }
  }

  func updateConfiguration(_ updatedConfiguration: MonitorConfiguration) {
    guard updatedConfiguration.id == configuration.id else { return }
    let targetChanged = updatedConfiguration.targetURL != configuration.targetURL
    configuration = updatedConfiguration
    guard targetChanged else { return }

    tianchengLogin?.stop()
    tianchengLogin = nil
    platformIdentified = false
    platformDetectionInProgress = false
    browserOnlyPage = false

    lastMetrics = nil
    lastMetricsScannedAt = nil
    latestDailyFinancialMetrics = nil
    consecutiveScanFailures = 0
    needsImmediateScan = true
    emit(.starting("后台地址已更新，正在重新连接"), nextScanAt: nil)
  }

  func stop() {
    isStarted = false
    monitoringEnabled = false
    tianchengLogin?.stop()
    authenticationDetectionWorkItem?.cancel()
    authenticationDetectionWorkItem = nil
    startupWorkItem?.cancel()
    startupWorkItem = nil
    startupID = nil
    nextScanWorkItem?.cancel()
    nextScanWorkItem = nil
    connectionKickoffWorkItem?.cancel()
    connectionKickoffWorkItem = nil
    connectionKickoffDeadline = nil
    scanTimeoutWorkItem?.cancel()
    scanTimeoutWorkItem = nil
    financialRefreshWorkItem?.cancel()
    financialRefreshWorkItem = nil
    isRefreshingFinancial = false
    nextScanAt = nil
    activeScanID = nil
    scanStartedAt = nil
    isScanning = false
    lastMetrics = nil
    lastMetricsScannedAt = nil
    latestDailyFinancialMetrics = nil
    webView.stopLoading()
  }

  private func scheduleConnectionKickoff(after delay: TimeInterval = 1) {
    connectionKickoffWorkItem?.cancel()
    if connectionKickoffDeadline == nil {
      connectionKickoffDeadline = Date().addingTimeInterval(10)
    }
    let workItem = DispatchWorkItem { [weak self] in
      guard let self, self.isStarted else { return }
      guard !self.browserOnlyPage else {
        self.connectionKickoffWorkItem = nil
        self.connectionKickoffDeadline = nil
        self.emitBrowserOnlyState()
        return
      }
      if self.webView.isLoading,
        let deadline = self.connectionKickoffDeadline,
        Date() < deadline
      {
        self.scheduleConnectionKickoff()
        return
      }
      if self.webView.isLoading {
        if !self.platformIdentified || self.tianchengLogin != nil {
          self.identifyPlatform { [weak self] in self?.scheduleConnectionKickoff(after: 0) }
          return
        }
        NSLog(
          "[SMSMonitor] %@ stopping a stalled page load before API scan",
          self.configuration.id
        )
        self.webView.stopLoading()
      }
      self.connectionKickoffWorkItem = nil
      self.connectionKickoffDeadline = nil
      self.needsImmediateScan = false
      self.scanNow()
    }
    connectionKickoffWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
  }

  private func finishScan(
    _ result: Result<Any, Error>,
    sampleLimit activeSampleLimit: Int,
    scanID: UUID
  ) {
    guard activeScanID == scanID else { return }
    NSLog("[SMSMonitor] %@ scan callback received", configuration.id)
    scanTimeoutWorkItem?.cancel()
    scanTimeoutWorkItem = nil
    activeScanID = nil
    isScanning = false

    guard activeSampleLimit == sampleLimit else {
      scanStartedAt = nil
      scanNow()
      return
    }

    switch result {
    case .failure(let error):
      handleScanFailure("扫描脚本执行失败：\(error.localizedDescription)")

    case .success(let rawValue):
      guard let payload = rawValue as? [String: Any], let kind = payload["kind"] as? String else {
        handleScanFailure("短信记录接口返回了无法识别的数据。")
        return
      }

      switch kind {
      case "ok":
        let statuses = payload["statuses"] as? [String] ?? []
        let metrics = MetricsCalculator.calculate(
          statuses: statuses,
          sampleLimit: activeSampleLimit
        )
        consecutiveScanFailures = 0
        apiAuthenticationValidationAttempted = false
        lastMetrics = metrics
        let scannedAt = Date()
        lastMetricsScannedAt = scannedAt

        if webView.url?.path == "/login" {
          handleAuthenticationRequired(
            "页面登录态已失效。",
            progressMessage: "页面会话已失效，正在自动登录"
          )
          return
        }

        scheduleNextScanAfterCurrentRun()
        ensureFinancialRefreshScheduled()
        if metrics.shouldAlert(threshold: configuration.alertThreshold) {
          emit(.alert(metrics, scannedAt), nextScanAt: nextScanAt)
        } else {
          emit(.healthy(metrics, scannedAt), nextScanAt: nextScanAt)
        }
        recycleInactivePageIfNeeded(now: scannedAt)

      case "auth":
        let message = payload["message"] as? String ?? "平台登录已失效。"
        handleAPIAuthenticationRequired(payload: payload, message: message)

      case "permission":
        smsPermissionBlocked = true
        lastMetrics = nil
        lastMetricsScannedAt = nil
        cancelNextScan()
        let message = payload["message"] as? String ?? "当前账号无短信记录查看权限，已停止短信查询。"
        emit(.error(message, Date()), nextScanAt: nil)

      case "sessionChanged":
        lastMetrics = nil
        lastMetricsScannedAt = nil
        latestDailyFinancialMetrics = nil
        emit(.starting("账号会话已变化，已丢弃旧数据"), nextScanAt: nil)
        scheduleNextScan(after: 5)

      default:
        let message = payload["message"] as? String ?? "短信记录接口扫描失败。"
        handleScanFailure(message)
      }
    }
  }

  private func handleScanFailure(_ message: String) {
    latestDailyFinancialMetrics = nil
    scanTimeoutWorkItem?.cancel()
    scanTimeoutWorkItem = nil
    activeScanID = nil
    isScanning = false
    scheduleNextScanAfterCurrentRun()
    consecutiveScanFailures += 1
    let shouldReload = ScanRecoveryPolicy.shouldReload(
      consecutiveFailures: consecutiveScanFailures
    )
    NSLog(
      "[SMSMonitor] %@ scan failure %ld/%ld: %@",
      configuration.id,
      consecutiveScanFailures,
      ScanRecoveryPolicy.defaultFailureThreshold,
      message
    )

    guard shouldReload else {
      emit(.error(message, Date()), nextScanAt: nextScanAt)
      return
    }

    consecutiveScanFailures = 0
    needsImmediateScan = true
    emit(
      .error("\(message)；正在自动重载后台连接。", Date()),
      nextScanAt: nextScanAt
    )
    webView.reload()
  }

  private static func dailyFinancialMetrics(from payload: [String: Any]) -> DailyFinancialMetrics? {
    guard let financial = payload["dailyFinancial"] as? [String: Any],
      let rechargeAmount = number(financial["rechargeAmount"]),
      let withdrawAmount = number(financial["withdrawAmount"]),
      rechargeAmount.isFinite,
      withdrawAmount.isFinite
    else { return nil }
    return DailyFinancialMetrics(
      rechargeAmount: rechargeAmount,
      withdrawAmount: withdrawAmount
    )
  }

  private static func number(_ value: Any?) -> Double? {
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) }
    return nil
  }

  private func scheduleFinancialRefresh(after delay: TimeInterval) {
    guard isStarted, monitoringEnabled, !browserOnlyPage, mockScenario == nil else { return }
    financialRefreshWorkItem?.cancel()
    let safeDelay = max(0, delay)
    let item = DispatchWorkItem { [weak self] in
      guard let self, self.isStarted else { return }
      self.financialRefreshWorkItem = nil
      self.refreshFinancialMetricsNow()
    }
    financialRefreshWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + safeDelay, execute: item)
  }

  private func ensureFinancialRefreshScheduled() {
    guard isStarted, monitoringEnabled, !browserOnlyPage, !financePermissionBlocked,
      !isRefreshingFinancial,
      financialRefreshWorkItem == nil || financialRefreshWorkItem?.isCancelled == true
    else { return }
    scheduleFinancialRefresh(after: 1)
  }

  private func refreshFinancialMetricsNow() {
    guard monitoringEnabled, !browserOnlyPage else { return }
    if !platformIdentified || tianchengLogin != nil {
      identifyPlatform { [weak self] in self?.refreshFinancialMetricsNow() }
      return
    }
    guard isStarted, !financePermissionBlocked, !manualAuthenticationRequired, !autoLoginInProgress, !credentialLoginPending else {
      if isStarted { scheduleFinancialRefresh(after: Self.financialRefreshInterval) }
      return
    }
    guard !isRefreshingFinancial else {
      scheduleFinancialRefresh(after: Self.financialRefreshInterval)
      return
    }
    guard let currentURL = webView.url, isMonitorOrigin(currentURL),
      !requiresInteractiveAuthentication(currentURL), !webView.isLoading,
      !currentURL.path.isEmpty, currentURL.path != "/"
    else {
      scheduleFinancialRefresh(after: Self.financialRefreshInterval)
      return
    }

    isRefreshingFinancial = true
    let epoch = authenticationEpoch
    webView.callAsyncJavaScript(
      FinanceScript.body,
      arguments: [
        "fallbackToken": credentialStore.profile(for: configuration.id)?.token ?? "",
        "platformID": configuration.id,
        "platformName": configuration.displayName,
      ],
      in: nil,
      in: .page
    ) { [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }
        guard self.isStarted, self.authenticationEpoch == epoch else { return }
        self.isRefreshingFinancial = false
        self.finishFinancialRefresh(result)
        self.scheduleFinancialRefresh(after: Self.financialRefreshInterval)
      }
    }
  }

  private func finishFinancialRefresh(_ result: Result<Any, Error>) {
    switch result {
    case .failure(let error):
      latestDailyFinancialMetrics = nil
      NSLog("[SMSMonitor] %@ financial refresh script failed: %@", configuration.id, error.localizedDescription)

    case .success(let rawValue):
      guard let payload = rawValue as? [String: Any],
        let kind = payload["kind"] as? String
      else {
        latestDailyFinancialMetrics = nil
        NSLog("[SMSMonitor] %@ financial refresh returned unrecognized data", configuration.id)
        break
      }

      if kind == "ok" {
        latestDailyFinancialMetrics = Self.dailyFinancialMetrics(from: payload)
        if latestDailyFinancialMetrics == nil {
          NSLog("[SMSMonitor] %@ financial refresh missing amount fields", configuration.id)
        }
      } else if kind == "permission" {
        latestDailyFinancialMetrics = nil
        financePermissionBlocked = true
        let message = payload["message"] as? String ?? "当前账号无财务数据查看权限，已停止财务查询。"
        NSLog("[SMSMonitor] %@ financial refresh permission blocked: %@", configuration.id, message)
      } else {
        latestDailyFinancialMetrics = nil
        if kind == "sessionChanged" {
          lastMetrics = nil
          lastMetricsScannedAt = nil
          emit(.starting("账号会话已变化，已丢弃旧数据"), nextScanAt: nil)
          scheduleNextScan(after: 5)
        }
        if kind == "auth" {
          let message = payload["message"] as? String ?? "今日统计登录态已失效，请重新登录。"
          NSLog("[SMSMonitor] %@ financial refresh requires authentication", configuration.id)
          handleAPIAuthenticationRequired(payload: payload, message: message)
          return
        }
        let message = payload["message"] as? String ?? "今日统计接口读取失败。"
        NSLog("[SMSMonitor] %@ financial refresh failed: %@", configuration.id, message)
      }
    }

    if let latestEmittedState {
      emit(latestEmittedState, nextScanAt: nextScanAt)
    }
  }

  private func recycleInactivePageIfNeeded(now: Date) {
    guard InactivePageMaintenancePolicy.shouldRecycle(
      isActive: isPageActive,
      inactiveSince: inactiveSince,
      lastSuccessfulScanAt: lastMetricsScannedAt,
      lastRecycleAt: lastPageRecycleAt,
      now: now,
      scanInterval: configuration.scanInterval
    ) else { return }

    lastPageRecycleAt = now
    inactiveSince = now
    needsImmediateScan = true
    NSLog("[SMSMonitor] %@ recycling long-idle WebKit page after fresh scan", configuration.id)
    webView.reload()
  }

  func credentialsDidChange() {
    if let tianchengLogin {
      if isStarted { tianchengLogin.credentialsDidChange() }
      return
    }
    guard monitoringEnabled else {
      if isStarted {
        platformIdentified = false
        platformDetectionInProgress = false
        identifyPlatform { [weak self] in self?.resumeAuthenticationOnlyIfNeeded() }
      }
      return
    }
    expediteStartupIfNeeded()
    guard !browserOnlyPage else {
      emitBrowserOnlyState()
      return
    }
    authenticationEpoch = UUID()
    activeScanID = nil
    isScanning = false
    isRefreshingFinancial = false
    scanTimeoutWorkItem?.cancel()
    lastMetrics = nil
    lastMetricsScannedAt = nil
    latestDailyFinancialMetrics = nil
    manualAuthenticationRequired = false
    apiAuthenticationValidationAttempted = false
    resetAccountIdentityRecovery()
    smsPermissionBlocked = false
    financePermissionBlocked = false
    captchaAutoLoginAttempts = 0
    totpAutoLoginAttempts = 0
    autoLoginCooldownUntil = nil
    autoLoginInProgress = false
    autoLoginStage = ""
    autoLoginOutcomeWorkItem?.cancel()
    guard let currentURL = webView.url, requiresAuthentication(currentURL) else { return }
    credentialLoginPending = true
    credentialStore.clearToken(for: configuration.id)
    handleAuthenticationRequired("自动登录配置已更新。")
  }

  fileprivate func handleSessionLifecycle(_ message: WKScriptMessage) {
    guard monitoringEnabled, !browserOnlyPage, message.frameInfo.isMainFrame,
      message.frameInfo.securityOrigin.host == configuration.targetURL.host
    else { return }
    let payload = message.body as? [String: Any]
    let event = payload?["event"] as? String ?? message.body as? String ?? ""
    let signedOutUsername = payload?["username"] as? String ?? ""
    NSLog(
      "[SMSMonitor] %@ session lifecycle %@ at %@",
      configuration.id,
      event,
      webView.url?.path ?? "(unknown)"
    )
    if event == "ended" {
      authenticationEpoch = UUID()
      let epoch = authenticationEpoch
      credentialStore.clearToken(for: configuration.id)
      manualAuthenticationRequired = true
      credentialLoginPending = false
      accountIdentityRecoveryPending = signedOutUsername.isEmpty
      accountIdentityConflict = !signedOutUsername.isEmpty
      accountIdentityCheckInProgress = false
      accountIdentityCheckAttempts = 0
      autoLoginInProgress = false
      autoLoginStage = ""
      autoLoginOutcomeWorkItem?.cancel()
      connectionKickoffWorkItem?.cancel()
      scanTimeoutWorkItem?.cancel()
      cancelNextScan()
      financialRefreshWorkItem?.cancel()
      financialRefreshWorkItem = nil
      activeScanID = nil
      isScanning = false
      isRefreshingFinancial = false
      lastMetrics = nil
      lastMetricsScannedAt = nil
      latestDailyFinancialMetrics = nil
      let host = message.frameInfo.securityOrigin.host
      let store = webView.configuration.websiteDataStore.httpCookieStore
      store.getAllCookies { [weak self] cookies in
        guard let self, self.authenticationEpoch == epoch, self.manualAuthenticationRequired else { return }
        let deletion = DispatchGroup()
        for cookie in cookies {
          let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
          if cookie.name.lowercased() == "token", host == domain || host.hasSuffix(".\(domain)") {
            deletion.enter()
            store.delete(cookie) { deletion.leave() }
          }
        }
        deletion.notify(queue: .main) { [weak self] in
          guard let self, self.authenticationEpoch == epoch, self.manualAuthenticationRequired,
            let profile = self.credentialStore.profile(for: self.configuration.id),
            PostLogoutLoginPolicy.shouldResume(
              signedOutUsername: signedOutUsername,
              configuredUsername: profile.username,
              canAutoLogin: profile.canAutoLogin
            )
          else { return }
          self.manualAuthenticationRequired = false
          self.credentialLoginPending = true
          self.resetAccountIdentityRecovery()
          self.captchaAutoLoginAttempts = 0
          self.totpAutoLoginAttempts = 0
          self.autoLoginCooldownUntil = nil
          self.handleAuthenticationRequired("旧 Token 已清除。", progressMessage: "正在使用已保存的同一账号重新登录")
        }
      }
      emit(.authenticationRequired("已退出账号，旧 Token 已作废；如需自动登录，请重新保存自动登录配置。"), nextScanAt: nil)
    } else if event == "authenticated" {
      guard let currentURL = webView.url, !requiresAuthentication(currentURL) else { return }
      manualAuthenticationRequired = false
      apiAuthenticationValidationAttempted = false
      credentialLoginPending = false
      resetAccountIdentityRecovery()
      smsPermissionBlocked = false
      financePermissionBlocked = false
      lastMetrics = nil
      lastMetricsScannedAt = nil
      latestDailyFinancialMetrics = nil
      persistCurrentToken()
      if isStarted {
        ensureFinancialRefreshScheduled()
        if !autoLoginInProgress { scheduleNextScan(after: 0) }
      }
    }
  }

  private func prepareAuthenticationRecovery(from payload: [String: Any]) {
    credentialStore.clearToken(for: configuration.id)
    credentialLoginPending = true
    let manualOnly = payload["manualOnly"] as? Bool == true
    guard manualOnly else {
      manualAuthenticationRequired = false
      resetAccountIdentityRecovery()
      return
    }

    let observedUsername = payload["sessionUsername"] as? String ?? ""
    if let profile = credentialStore.profile(for: configuration.id),
      PostLogoutLoginPolicy.shouldResume(
        signedOutUsername: observedUsername,
        configuredUsername: profile.username,
        canAutoLogin: profile.canAutoLogin
      )
    {
      manualAuthenticationRequired = false
      resetAccountIdentityRecovery()
      captchaAutoLoginAttempts = 0
      totpAutoLoginAttempts = 0
      autoLoginCooldownUntil = nil
      return
    }

    manualAuthenticationRequired = true
    credentialLoginPending = false
    accountIdentityRecoveryPending = observedUsername.isEmpty
    accountIdentityConflict = !observedUsername.isEmpty
    accountIdentityCheckInProgress = false
    accountIdentityCheckAttempts = 0
  }

  private func handleAPIAuthenticationRequired(payload: [String: Any], message: String) {
    latestDailyFinancialMetrics = nil

    if payload["manualOnly"] as? Bool == true {
      prepareAuthenticationRecovery(from: payload)
      handleAuthenticationRequired(message)
      return
    }

    guard let currentURL = webView.url, !requiresInteractiveAuthentication(currentURL) else {
      prepareAuthenticationRecovery(from: payload)
      handleAuthenticationRequired(message)
      return
    }

    if !apiAuthenticationValidationAttempted {
      apiAuthenticationValidationAttempted = true
      needsImmediateScan = true
      cancelNextScan()
      NSLog(
        "[SMSMonitor] %@ API authentication failed on an authenticated page; reloading once to validate the browser session",
        configuration.id
      )
      emit(.starting("接口登录态异常，正在刷新当前页面确认"), nextScanAt: nil)
      webView.reload()
      return
    }

    NSLog(
      "[SMSMonitor] %@ API authentication is still failing while the page remains authenticated; automatic login suppressed",
      configuration.id
    )
    scheduleNextScanAfterCurrentRun()
    emit(
      .error("\(message) 网页仍保持登录，客户端不会反复退出登录；稍后重试接口。", Date()),
      nextScanAt: nextScanAt
    )
  }

  private func resetAccountIdentityRecovery() {
    accountIdentityRecoveryPending = false
    accountIdentityConflict = false
    accountIdentityCheckInProgress = false
    accountIdentityCheckAttempts = 0
  }

  private func attemptLoginPageIdentityRecovery() {
    guard manualAuthenticationRequired, accountIdentityRecoveryPending,
      !accountIdentityConflict, !accountIdentityCheckInProgress,
      let currentURL = webView.url, currentURL.path == "/login",
      let profile = credentialStore.profile(for: configuration.id), profile.canAutoLogin
    else { return }

    accountIdentityCheckInProgress = true
    let epoch = authenticationEpoch
    loginAutomation.identity(in: webView) { [weak self] result in
      guard let self, self.authenticationEpoch == epoch else { return }
      self.accountIdentityCheckInProgress = false
      guard self.manualAuthenticationRequired, self.accountIdentityRecoveryPending else { return }

      guard case .success(let identity) = result, !identity.manual else {
        self.accountIdentityRecoveryPending = false
        return
      }
      if identity.username.isEmpty, self.accountIdentityCheckAttempts < 5 {
        self.accountIdentityCheckAttempts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
          self?.attemptLoginPageIdentityRecovery()
        }
        return
      }
      guard PostLogoutLoginPolicy.shouldResume(
        signedOutUsername: "",
        loginPageUsername: identity.username,
        configuredUsername: profile.username,
        canAutoLogin: profile.canAutoLogin
      ) else {
        self.accountIdentityRecoveryPending = false
        self.accountIdentityConflict = !identity.username.isEmpty
        return
      }

      self.manualAuthenticationRequired = false
      self.credentialLoginPending = true
      self.resetAccountIdentityRecovery()
      self.captchaAutoLoginAttempts = 0
      self.totpAutoLoginAttempts = 0
      self.autoLoginCooldownUntil = nil
      self.handleAuthenticationRequired(
        "登录页账号已确认。",
        progressMessage: "正在使用已保存的同一账号重新登录"
      )
    }
  }

  private func handleAuthenticationRequired(
    _ message: String,
    progressMessage: String = "Token 已失效，正在自动登录"
  ) {
    lastMetrics = nil
    lastMetricsScannedAt = nil
    latestDailyFinancialMetrics = nil
    scanTimeoutWorkItem?.cancel()
    scanTimeoutWorkItem = nil
    activeScanID = nil
    scanStartedAt = nil
    isScanning = false
    consecutiveScanFailures = 0
    needsImmediateScan = true
    scheduleNextScan(after: configuration.scanInterval)

    guard !manualAuthenticationRequired else {
      autoLoginInProgress = false
      autoLoginStage = ""
      autoLoginOutcomeWorkItem?.cancel()
      if accountIdentityRecoveryPending && !accountIdentityConflict {
        if webView.url?.path == "/login" {
          emit(.starting("正在确认登录页账号"), nextScanAt: nextScanAt)
          attemptLoginPageIdentityRecovery()
        } else {
          emit(.starting("正在打开登录页确认账号"), nextScanAt: nextScanAt)
          webView.load(URLRequest(url: loginURL))
        }
        return
      }
      emit(.authenticationRequired("当前账号会话失效，请人工确认登录账号；不会改用旧账号。"), nextScanAt: nextScanAt)
      return
    }
    guard let profile = credentialStore.profile(for: configuration.id), profile.canAutoLogin else {
      NSLog("[SMSMonitor] %@ automatic login skipped: no enabled profile", configuration.id)
      emit(.authenticationRequired("\(message) 请打开对应后台标签完成登录。"), nextScanAt: nextScanAt)
      return
    }
    if let cooldown = autoLoginCooldownUntil {
      if cooldown > Date() {
        emit(
          .authenticationRequired("自动登录连续失败，已暂停至 \(Self.timeText(cooldown))，可检查本地账号配置后重试。"),
          nextScanAt: nextScanAt
        )
        return
      }
      captchaAutoLoginAttempts = 0
      totpAutoLoginAttempts = 0
      autoLoginCooldownUntil = nil
    }

    emit(.starting(progressMessage), nextScanAt: nextScanAt)
    if let currentURL = webView.url, requiresAuthentication(currentURL) {
      attemptAutoLogin(profile: profile, url: currentURL)
    } else {
      webView.load(URLRequest(url: loginURL))
    }
  }

  private func attemptAutoLogin(profile: LocalLoginProfile, url: URL) {
    guard !manualAuthenticationRequired else { return }
    guard !autoLoginInProgress else { return }
    guard profile.canAutoLogin else {
      emit(.authenticationRequired("请先配置本后台的自动登录账号。"), nextScanAt: nextScanAt)
      return
    }
    if url.path == "/unlock-ip" {
      emit(.authenticationRequired("平台要求人工完成 IP 解锁，自动登录已暂停。"), nextScanAt: nextScanAt)
      return
    }
    let isTOTP = url.path == "/ga-auth"
    let attempts = isTOTP ? totpAutoLoginAttempts : captchaAutoLoginAttempts
    let maximumAttempts = isTOTP
      ? AutoLoginAttemptPolicy.maximumTOTPAttempts
      : AutoLoginAttemptPolicy.maximumCaptchaAttempts
    guard attempts < maximumAttempts else {
      pauseAutoLogin(
        phaseName: isTOTP ? "Google 验证码" : "图片验证码",
        maximumAttempts: maximumAttempts
      )
      return
    }

    autoLoginInProgress = true
    loginCompletionDeadline = nil
    emit(
      .starting(
        "正在自动登录（\(isTOTP ? "Google 验证码" : "图片验证码") \(attempts + 1)/\(maximumAttempts)）"
      ),
      nextScanAt: nextScanAt
    )
    let epoch = authenticationEpoch
    loginAutomation.snapshot(in: webView) { [weak self] result in
      guard let self, self.authenticationEpoch == epoch, !self.manualAuthenticationRequired else { return }
      switch result {
      case .failure(let error):
        NSLog("[SMSMonitor] %@ login snapshot failed: %@", self.configuration.id, error.localizedDescription)
        self.retryAutoLogin("无法读取登录页面：\(error.localizedDescription)")
      case .success(let snapshot):
        NSLog("[SMSMonitor] %@ login snapshot kind: %@", self.configuration.id, snapshot.kind)
        switch snapshot.kind {
        case "login":
          self.solveCaptchaAndSubmit(profile: profile, dataURL: snapshot.captchaDataURL)
        case "totp":
          self.generateAndSubmitTOTP(
            profile: profile,
            clockOffsetMilliseconds: snapshot.clockOffsetMilliseconds
          )
        case "manual":
          self.pauseForManualLogin()
        case "authenticated":
          self.confirmAutoLoginCompletion()
        case "unlock-ip":
          self.autoLoginInProgress = false
          self.emit(
            .authenticationRequired("平台要求人工完成 IP 解锁，自动登录已暂停。"),
            nextScanAt: self.nextScanAt
          )
        default:
          self.retryAutoLogin("登录页面状态无法识别")
        }
      }
    }
  }

  private func solveCaptchaAndSubmit(profile: LocalLoginProfile, dataURL: String) {
    guard !dataURL.isEmpty else {
      retryAutoLogin("验证码图片尚未加载")
      return
    }
    let epoch = authenticationEpoch
    automationRuntime.recognize(dataURL: dataURL) { [weak self] result in
      guard let self, self.authenticationEpoch == epoch, !self.manualAuthenticationRequired else { return }
      switch result {
      case .failure(let error):
        self.retryAutoLogin("本地验证码识别失败：\(error.localizedDescription)")
      case .success(let captcha):
        guard captcha.range(of: #"^[0-9A-Za-z]{4}$"#, options: .regularExpression) != nil else {
          self.loginAutomation.refreshCaptcha(in: self.webView)
          self.retryAutoLogin("本地验证码识别结果无效")
          return
        }
        self.loginAutomation.submitLogin(
          in: self.webView,
          profile: profile,
          captcha: captcha
        ) { [weak self] submitResult in
          guard let self, self.authenticationEpoch == epoch else { return }
          switch submitResult {
          case .failure(let error):
            self.retryAutoLogin("登录表单提交失败：\(error.localizedDescription)")
          case .success(let submission):
            if submission.manual {
              self.pauseForManualLogin()
              return
            }
            guard submission.submitted else {
              self.retryAutoLogin(
                submission.message.isEmpty ? "登录表单尚未准备完成" : submission.message
              )
              return
            }
            self.autoLoginStage = "login"
            self.scheduleAutoLoginOutcomeCheck()
          }
        }
      }
    }
  }

  private func generateAndSubmitTOTP(
    profile: LocalLoginProfile,
    clockOffsetMilliseconds: Double
  ) {
    let epoch = authenticationEpoch
    let secret = profile.totpSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !secret.isEmpty else {
      autoLoginInProgress = false
      emit(
        .authenticationRequired("账号密码已通过，但本地未配置 Google 密钥，请人工完成二次验证。"),
        nextScanAt: nextScanAt
      )
      return
    }
    guard TOTPSecretPolicy.isValid(secret) else {
      autoLoginInProgress = false
      credentialStore.clearToken(for: configuration.id)
      emit(
        .authenticationRequired(
          "Google 密钥格式无效，请重新保存原始 Base32 密钥或完整 otpauth:// 链接。"
        ),
        nextScanAt: nextScanAt
      )
      return
    }
    let serverOffset = clockOffsetMilliseconds.isFinite
      && abs(clockOffsetMilliseconds) <= 43_200_000
      ? clockOffsetMilliseconds / 1_000
      : 0
    let retryOffsets = [0, -30, 30, -60, 60]
    let offset = serverOffset
      + Double(retryOffsets[min(totpAutoLoginAttempts, retryOffsets.count - 1)])
    NSLog(
      "[SMSMonitor] %@ TOTP attempt %d using server offset %.1f seconds and retry offset %d seconds",
      configuration.id,
      totpAutoLoginAttempts + 1,
      serverOffset,
      retryOffsets[min(totpAutoLoginAttempts, retryOffsets.count - 1)]
    )
    let adjustedNow = Date().addingTimeInterval(TimeInterval(offset))
    let cyclePosition = adjustedNow.timeIntervalSince1970.truncatingRemainder(dividingBy: 30)
    let delay = cyclePosition > 24 ? 6.5 : 0
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self, self.authenticationEpoch == epoch else { return }
      guard self.autoLoginInProgress else { return }
      let timestamp = Date().addingTimeInterval(TimeInterval(offset))
      self.automationRuntime.generateTOTP(secret: secret, timestamp: timestamp) { [weak self] result in
        guard let self, self.authenticationEpoch == epoch, !self.manualAuthenticationRequired else { return }
        switch result {
        case .failure(let error):
          NSLog("[SMSMonitor] %@ TOTP generation failed: %@", self.configuration.id, error.localizedDescription)
          self.retryAutoLogin("Google 动态码生成失败：\(error.localizedDescription)")
        case .success(let code):
          self.loginAutomation.submitTOTP(in: self.webView, code: code) { [weak self] submitResult in
            guard let self, self.authenticationEpoch == epoch else { return }
            guard (try? submitResult.get()) == true else {
              NSLog("[SMSMonitor] %@ TOTP form submission was not accepted", self.configuration.id)
              self.retryAutoLogin("Google 验证页面尚未准备完成")
              return
            }
            NSLog("[SMSMonitor] %@ TOTP form submitted", self.configuration.id)
            self.autoLoginStage = "totp"
            self.scheduleAutoLoginOutcomeCheck()
          }
        }
      }
    }
  }

  private func scheduleAutoLoginOutcomeCheck(after delay: TimeInterval = 7) {
    autoLoginOutcomeWorkItem?.cancel()
    let epoch = authenticationEpoch
    let item = DispatchWorkItem { [weak self] in
      guard let self, self.authenticationEpoch == epoch, !self.manualAuthenticationRequired else { return }
      self.autoLoginInProgress = false
      guard let currentURL = self.webView.url else {
        self.retryAutoLogin("登录后页面没有返回有效地址")
        return
      }
      if self.requiresAuthentication(currentURL) {
        if currentURL.path == "/ga-auth", self.autoLoginStage != "totp",
          let profile = self.credentialStore.profile(for: self.configuration.id)
        {
          self.autoLoginStage = ""
          self.attemptAutoLogin(profile: profile, url: currentURL)
        } else if currentURL.path == "/ga-auth" {
          self.retryAutoLogin("Google 验证未通过，正在尝试备用时间窗口")
        } else {
          self.loginAutomation.refreshCaptcha(in: self.webView)
          self.retryAutoLogin("登录尚未通过，正在更换验证码重试")
        }
        return
      }
      self.confirmAutoLoginCompletion()
    }
    autoLoginOutcomeWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
  }

  private func confirmAutoLoginCompletion() {
    guard !manualAuthenticationRequired,
      let url = webView.url, isMonitorOrigin(url), !requiresAuthentication(url),
      let profile = credentialStore.profile(for: configuration.id)
    else { return }
    if let cooldown = autoLoginCooldownUntil, cooldown > Date() { return }
    if loginCompletionDeadline == nil {
      loginCompletionDeadline = Date().addingTimeInterval(30)
    }
    guard Date() < loginCompletionDeadline! else {
      autoLoginInProgress = false
      autoLoginCooldownUntil = Date().addingTimeInterval(Self.autoLoginCooldown)
      autoLoginOutcomeWorkItem?.cancel()
      emit(.authenticationRequired("登录后页面或会话未就绪，已暂停自动重试；不会重新提交账号密码。"), nextScanAt: nextScanAt)
      return
    }
    autoLoginInProgress = true
    // NPG visits / between password login, Google verification and the app
    // route. A completed document navigation is not completed authentication.
    guard !webView.isLoading, !url.path.isEmpty, url.path != "/" else {
      scheduleAutoLoginOutcomeCheck(after: 1)
      return
    }
    let epoch = authenticationEpoch
    loginAutomation.extractToken(in: webView, expectedUsername: profile.username) { [weak self] token in
      guard let self, self.authenticationEpoch == epoch, !self.manualAuthenticationRequired else { return }
      guard self.webView.url == url, !self.webView.isLoading, !token.isEmpty else {
        self.scheduleAutoLoginOutcomeCheck(after: 1)
        return
      }
      self.completeAutoLogin(token: token)
    }
  }

  private func retryAutoLogin(_ message: String) {
    guard !manualAuthenticationRequired else { return }
    NSLog("[SMSMonitor] %@ automatic login retry: %@", configuration.id, message)
    let epoch = authenticationEpoch
    autoLoginInProgress = false
    autoLoginStage = ""
    let isTOTP = webView.url?.path == "/ga-auth"
    let phaseName = isTOTP ? "Google 验证码" : "图片验证码"
    let maximumAttempts = isTOTP
      ? AutoLoginAttemptPolicy.maximumTOTPAttempts
      : AutoLoginAttemptPolicy.maximumCaptchaAttempts
    if isTOTP {
      totpAutoLoginAttempts += 1
    } else {
      captchaAutoLoginAttempts += 1
    }
    let attempts = isTOTP ? totpAutoLoginAttempts : captchaAutoLoginAttempts
    guard attempts < maximumAttempts else {
      pauseAutoLogin(
        phaseName: phaseName,
        maximumAttempts: maximumAttempts,
        detail: message
      )
      return
    }
    emit(
      .starting("\(message)，将继续尝试\(phaseName)（\(attempts + 1)/\(maximumAttempts)）"),
      nextScanAt: nextScanAt
    )
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      guard let self, let currentURL = self.webView.url,
        self.authenticationEpoch == epoch,
        let profile = self.credentialStore.profile(for: self.configuration.id)
      else { return }
      self.attemptAutoLogin(profile: profile, url: currentURL)
    }
  }

  private func pauseAutoLogin(
    phaseName: String,
    maximumAttempts: Int,
    detail: String = ""
  ) {
    autoLoginInProgress = false
    autoLoginStage = ""
    let cooldown = Date().addingTimeInterval(Self.autoLoginCooldown)
    autoLoginCooldownUntil = cooldown
    let suffix = detail.isEmpty ? "" : "（\(detail)）"
    emit(
      .authenticationRequired(
        "\(phaseName)已连续失败 \(maximumAttempts) 次\(suffix)，请人工处理；自动登录暂停至 \(Self.timeText(cooldown))。"
      ),
      nextScanAt: nextScanAt
    )
  }

  private func pauseForManualLogin() {
    autoLoginInProgress = false
    autoLoginStage = ""
    autoLoginOutcomeWorkItem?.cancel()
    emit(
      .authenticationRequired("检测到人工输入，自动登录已暂停，请完成验证码登录。"),
      nextScanAt: nextScanAt
    )
  }

  private func completeAutoLogin(token: String) {
    authenticationEpoch = UUID()
    activeScanID = nil
    isScanning = false
    isRefreshingFinancial = false
    scanTimeoutWorkItem?.cancel()
    loginCompletionDeadline = nil
    credentialLoginPending = false
    manualAuthenticationRequired = false
    resetAccountIdentityRecovery()
    autoLoginInProgress = false
    autoLoginStage = ""
    captchaAutoLoginAttempts = 0
    totpAutoLoginAttempts = 0
    autoLoginCooldownUntil = nil
    autoLoginOutcomeWorkItem?.cancel()
    NSLog("[SMSMonitor] %@ login confirmed at %@; recovery flag cleared", configuration.id, webView.url?.path ?? "")
    needsImmediateScan = true
    if !token.isEmpty {
      credentialStore.updateToken(token, for: configuration.id)
    }
    persistCurrentToken()
    ensureFinancialRefreshScheduled()
    emit(.starting("自动登录成功，正在恢复监控"), nextScanAt: nextScanAt)
    guard let currentURL = webView.url, isMonitorOrigin(currentURL) else {
      webView.load(URLRequest(url: configuration.targetURL))
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      self?.scanNow()
    }
  }

  private func persistCurrentToken() {
    guard !manualAuthenticationRequired else { return }
    guard let currentURL = webView.url, !requiresAuthentication(currentURL) else { return }
    let epoch = authenticationEpoch
    guard let profile = credentialStore.profile(for: configuration.id) else { return }
    loginAutomation.extractToken(in: webView, expectedUsername: profile.username) { [weak self] token in
      guard let self, self.authenticationEpoch == epoch, !self.manualAuthenticationRequired else { return }
      guard self.credentialStore.profile(for: self.configuration.id)?.username == profile.username else { return }
      if !token.isEmpty {
        self.credentialStore.updateToken(token, for: self.configuration.id)
        return
      }
    }
  }

  private func persistCookieToken() {
    guard let host = configuration.targetURL.host else { return }
    webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
      guard let self else { return }
      let token = cookies.first { cookie in
        let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let matchesHost = host == domain || host.hasSuffix(".\(domain)")
        return matchesHost && cookie.name.lowercased() == "token" && cookie.value.count > 12
      }?.value ?? ""
      guard !token.isEmpty else { return }
      DispatchQueue.main.async {
        self.credentialStore.updateToken(token, for: self.configuration.id)
      }
    }
  }

  private var loginURL: URL {
    var components = URLComponents(
      url: configuration.targetURL,
      resolvingAgainstBaseURL: false
    )
    components?.path = "/login"
    components?.query = nil
    return components?.url ?? configuration.targetURL
  }

  private var monitoringPageURL: URL {
    guard var components = URLComponents(url: configuration.targetURL, resolvingAgainstBaseURL: false)
    else { return configuration.targetURL }
    if ["/", "/login", "/ga-auth", "/unlock-ip"].contains(components.path) {
      components.path = "/sms-record-list"
    }
    return components.url ?? configuration.targetURL
  }

  private static func timeText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
  }

  private func scheduleNextScan(after delay: TimeInterval) {
    nextScanWorkItem?.cancel()
    let safeDelay = max(0, delay)
    nextScanAt = Date().addingTimeInterval(safeDelay)
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.nextScanWorkItem = nil
      self.nextScanAt = nil
      self.scanNow()
    }
    nextScanWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + safeDelay, execute: item)
  }

  private func cancelNextScan() {
    nextScanWorkItem?.cancel()
    nextScanWorkItem = nil
    nextScanAt = nil
  }

  private func scheduleNextScanAfterCurrentRun() {
    let duration = scanStartedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
    scanStartedAt = nil
    scheduleNextScan(
      after: MonitorRefreshPolicy.nextScanDelay(
        scanInterval: configuration.scanInterval,
        scanDuration: duration
      )
    )
  }

  private func scheduleScanTimeout(for scanID: UUID) {
    scanTimeoutWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self, self.activeScanID == scanID else { return }
      self.scanTimeoutWorkItem = nil
      self.activeScanID = nil
      self.scanStartedAt = nil
      self.isScanning = false
      self.consecutiveScanFailures += 1
      self.needsImmediateScan = true
      self.scheduleNextScan(after: self.configuration.scanInterval)
      let seconds = Int(Self.maximumScanDuration)
      let message = "扫描超过 \(seconds) 秒；正在自动重载后台连接。"
      NSLog("[SMSMonitor] %@ scan timeout: %@", self.configuration.id, message)
      self.emit(.error(message, Date()), nextScanAt: self.nextScanAt)
      self.webView.reload()
    }
    scanTimeoutWorkItem = item
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.maximumScanDuration,
      execute: item
    )
  }

  private func emit(_ state: AppMonitorState, nextScanAt: Date?) {
    latestEmittedState = state
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
    let configuredSuccessCount =
      scenario == "fleet"
      ? mockSuccessCounts[configuration.id, default: defaultSuccessCount]
      : defaultSuccessCount
    let successRate = Double(configuredSuccessCount) / Double(configuration.sampleLimit)
    let successCount = min(sampleLimit, Int((Double(sampleLimit) * successRate).rounded()))
    let statuses =
      Array(repeating: "SUCCESS", count: successCount)
      + Array(repeating: "SENT", count: sampleLimit - successCount)
    let metrics = MetricsCalculator.calculate(
      statuses: statuses,
      sampleLimit: sampleLimit
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

  private func requiresInteractiveAuthentication(_ url: URL) -> Bool {
    requiresAuthentication(url)
  }

  private func resumeAuthenticationOnlyIfNeeded() {
    guard isStarted, !monitoringEnabled, let url = webView.url,
      requiresAuthentication(url)
    else { return }
    NSLog(
      "[SMSMonitor] %@ resuming authentication-only login at %@",
      configuration.id, url.path
    )
    handleAuthenticationRequired(
      "平台需要重新登录。",
      progressMessage: "正在使用已保存账号登录当前页面"
    )
  }

  private func isMonitorOrigin(_ url: URL) -> Bool {
    url.scheme == configuration.targetURL.scheme
      && url.host == configuration.targetURL.host
      && url.port == configuration.targetURL.port
  }

  private func identifyPlatform(continueNPG: @escaping () -> Void) {
    guard isStarted, let url = webView.url, isMonitorOrigin(url) else { return }
    if let tianchengLogin { tianchengLogin.start(); return }
    if browserOnlyPage {
      emitBrowserOnlyState()
      return
    }
    if platformIdentified { continueNPG(); return }
    guard !platformDetectionInProgress else { return }
    platformDetectionInProgress = true
    TianchengLoginController.detect(in: webView) { [weak self] detected in
      guard let self else { return }
      self.platformDetectionInProgress = false
      guard self.isStarted, self.webView.url == url, self.isMonitorOrigin(url) else { return }
      guard let detected else {
        if self.monitoringEnabled {
          self.scheduleNextScan(after: 5)
        } else {
          self.scheduleAuthenticationOnlyDetection()
        }
        return
      }
      self.platformIdentified = true
      if detected {
        self.cancelNextScan()
        self.financialRefreshWorkItem?.cancel()
        self.financialRefreshWorkItem = nil
        self.latestDailyFinancialMetrics = nil
        self.lastMetrics = nil
        self.lastMetricsScannedAt = nil
        self.tianchengLogin = TianchengLoginController(
          webView: self.webView, origin: self.configuration.targetURL,
          credentialID: self.configuration.id, store: self.credentialStore,
          runtime: self.automationRuntime
        ) { [weak self] state in self?.emit(state, nextScanAt: nil) }
        self.tianchengLogin?.start()
      } else if self.monitoringEnabled {
        if PlatformRoutingPolicy.shouldUseNPGMonitoring(
          configurationID: self.configuration.id,
          targetURL: self.configuration.targetURL
        ) {
          continueNPG()
          self.ensureFinancialRefreshScheduled()
        } else {
          self.enterBrowserOnlyMode()
        }
      } else {
        continueNPG()
      }
    }
  }

  private func scheduleAuthenticationOnlyDetection(after delay: TimeInterval = 2) {
    authenticationDetectionWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self, self.isStarted, !self.monitoringEnabled else { return }
      self.authenticationDetectionWorkItem = nil
      if self.tianchengLogin == nil, let url = self.webView.url,
        self.requiresAuthentication(url), !self.autoLoginInProgress
      {
        self.resumeAuthenticationOnlyIfNeeded()
      } else if !self.platformIdentified, self.tianchengLogin == nil, !self.browserOnlyPage {
        self.identifyPlatform {}
      }
      self.scheduleAuthenticationOnlyDetection()
    }
    authenticationDetectionWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
  }

  private func enterBrowserOnlyMode() {
    browserOnlyPage = true
    cancelNextScan()
    connectionKickoffWorkItem?.cancel()
    connectionKickoffWorkItem = nil
    connectionKickoffDeadline = nil
    scanTimeoutWorkItem?.cancel()
    scanTimeoutWorkItem = nil
    financialRefreshWorkItem?.cancel()
    financialRefreshWorkItem = nil
    activeScanID = nil
    scanStartedAt = nil
    isScanning = false
    isRefreshingFinancial = false
    latestDailyFinancialMetrics = nil
    lastMetrics = nil
    lastMetricsScannedAt = nil
    emitBrowserOnlyState()
  }

  private func emitBrowserOnlyState() {
    emit(
      .browserOnly("仅浏览页面；未识别为已接入平台，不发送短信或财务查询。"),
      nextScanAt: nil
    )
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard let url = webView.url else { return }
    NSLog(
      "[SMSMonitor] %@ navigation finished at %@%@",
      configuration.id,
      url.host ?? "(unknown)",
      url.path
    )

    if !monitoringEnabled, requiresAuthentication(url) {
      resumeAuthenticationOnlyIfNeeded()
      return
    }

    if browserOnlyPage {
      emitBrowserOnlyState()
      return
    }

    if !platformIdentified || tianchengLogin != nil {
      identifyPlatform { [weak self] in self?.webView(webView, didFinish: navigation) }
      return
    }

    guard monitoringEnabled else {
      resumeAuthenticationOnlyIfNeeded()
      return
    }

    if requiresInteractiveAuthentication(url) {
      handleAuthenticationRequired("平台需要重新登录。")
      return
    }

    guard isMonitorOrigin(url) else { return }
    if autoLoginInProgress || !autoLoginStage.isEmpty || credentialLoginPending {
      scheduleAutoLoginOutcomeCheck(after: 1)
      return
    }
    persistCurrentToken()
    ensureFinancialRefreshScheduled()
    guard needsImmediateScan else { return }
    scheduleConnectionKickoff()
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    guard monitoringEnabled else { return }
    needsImmediateScan = true
    handleScanFailure("平台页面加载失败：\(error.localizedDescription)")
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    if #available(macOS 11.3, *), navigationAction.shouldPerformDownload {
      decisionHandler(.download)
    } else {
      decisionHandler(.allow)
    }
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
  ) {
    if #available(macOS 11.3, *),
      (!navigationResponse.canShowMIMEType || isAttachmentResponse(navigationResponse))
    {
      decisionHandler(.download)
    } else {
      decisionHandler(.allow)
    }
  }

  @available(macOS 11.3, *)
  func webView(
    _ webView: WKWebView,
    navigationAction: WKNavigationAction,
    didBecome download: WKDownload
  ) {
    PlatformDownloadCoordinator.shared.attach(download)
  }

  @available(macOS 11.3, *)
  func webView(
    _ webView: WKWebView,
    navigationResponse: WKNavigationResponse,
    didBecome download: WKDownload
  ) {
    PlatformDownloadCoordinator.shared.attach(download)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    if browserOnlyPage {
      emitBrowserOnlyState()
      webView.reload()
      return
    }
    if !monitoringEnabled {
      tianchengLogin?.stop()
      tianchengLogin = nil
      platformIdentified = false
      platformDetectionInProgress = false
      webView.reload()
      return
    }
    scanTimeoutWorkItem?.cancel()
    scanTimeoutWorkItem = nil
    activeScanID = nil
    scanStartedAt = nil
    isScanning = false
    autoLoginInProgress = false
    autoLoginStage = ""
    autoLoginOutcomeWorkItem?.cancel()
    consecutiveScanFailures = 0
    needsImmediateScan = true
    scheduleNextScan(after: configuration.scanInterval)
    emit(.error("平台页面进程已重启，正在恢复。", Date()), nextScanAt: nextScanAt)
    webView.reload()
  }
}

final class MonitorController {
  let configurations: [MonitorConfiguration]
  var onStateChange: ((FleetMonitorSnapshot, String?) -> Void)?
  var onSampleLimitChange: ((Int) -> Void)?
  private(set) var sampleLimit: Int

  private static let sampleLimitDefaultsKey = "SMSMonitorSampleLimit.v1"
  private static let disabledModuleIDsDefaultsKey = "SMSMonitorDisabledModuleIDs.v1"
  private let credentialStore: LocalCredentialStore
  private let automationRuntime: LocalAutomationRuntime
  private let loginAutomation: LoginPageAutomation
  private var monitorsByID: [String: ModuleMonitorController]
  private var orderedMonitorIDs: [String]
  private let workspaceController: PlatformWorkspaceController
  private var snapshotsByID: [String: ModuleMonitorSnapshot]
  private var activityToken: NSObjectProtocol?
  private var hasStarted = false
  private var healthCheckWorkItem: DispatchWorkItem?
  private var disabledModuleIDs: Set<String>

  init(configurations: [MonitorConfiguration]) {
    self.configurations = configurations
    let storedLimit = UserDefaults.standard.integer(forKey: Self.sampleLimitDefaultsKey)
    let initialSampleLimit = SampleLimitPolicy.normalize(
      storedLimit == 0 ? SampleLimitPolicy.defaultValue : storedLimit
    )
    self.sampleLimit = initialSampleLimit
    let storedDisabledModuleIDs = Set(
      UserDefaults.standard.stringArray(forKey: Self.disabledModuleIDsDefaultsKey) ?? []
    )
    self.disabledModuleIDs = storedDisabledModuleIDs

    let credentialStore = LocalCredentialStore()
    let automationRuntime = LocalAutomationRuntime()
    let loginAutomation = LoginPageAutomation()
    self.credentialStore = credentialStore
    self.automationRuntime = automationRuntime
    self.loginAutomation = loginAutomation
    let monitors = configurations.map {
      ModuleMonitorController(
        configuration: $0,
        sampleLimit: initialSampleLimit,
        credentialStore: credentialStore,
        automationRuntime: automationRuntime,
        loginAutomation: loginAutomation
      )
    }
    self.monitorsByID = Dictionary(
      uniqueKeysWithValues: monitors.map { ($0.configuration.id, $0) }
    )
    self.orderedMonitorIDs = configurations.map(\.id)
    self.workspaceController = PlatformWorkspaceController(
      sampleLimit: initialSampleLimit,
      monitoredPages: monitors.map {
        MonitoredPlatformPage(
          configuration: $0.configuration,
          webView: $0.webView
        )
      },
      credentialStore: credentialStore
    )
    self.snapshotsByID = Dictionary(
      uniqueKeysWithValues: configurations.map {
        (
          $0.id,
          ModuleMonitorSnapshot(
            configuration: $0,
            state: storedDisabledModuleIDs.contains($0.id) ? .disabled : .starting("等待连接"),
            nextScanAt: nil
          )
        )
      }
    )
    self.workspaceController.onAutoLoginSettings = { [weak self] target in
      self?.showAutoLoginSettings(target: target)
    }
    self.workspaceController.onSampleLimitSettings = { [weak self] in
      self?.showSampleLimitSettings()
    }
    self.workspaceController.onPageAdded = { [weak self] page in
      self?.registerPage(page)
    }
    self.workspaceController.onPageUpdated = { [weak self] page in
      self?.updatePage(page)
    }
    self.workspaceController.onPageRemoved = { [weak self] credentialID in
      self?.removePage(credentialID: credentialID)
    }
    self.workspaceController.onPageOrderChanged = { [weak self] credentialIDs in
      self?.applyPageOrder(credentialIDs)
    }
    self.workspaceController.onSelectedPageChanged = { [weak self] credentialID in
      self?.applyActivePage(credentialID)
    }

    for monitor in monitors {
      bind(monitor)
    }
    let activePages = workspaceController.pageDescriptors()
    let activeIDs = Set(activePages.map(\.credentialID))
    for page in activePages {
      registerPage(page)
    }
    for credentialID in Array(monitorsByID.keys) where !activeIDs.contains(credentialID) {
      removePage(credentialID: credentialID)
    }
    applyPageOrder(activePages.map(\.credentialID))
    applyActivePage(workspaceController.selectedCredentialID)
  }

  deinit {
    healthCheckWorkItem?.cancel()
    if let activityToken {
      ProcessInfo.processInfo.endActivity(activityToken)
    }
  }

  func start() {
    activityToken = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled],
      reason: "Scan SMS delivery success rates for all configured platforms"
    )

    hasStarted = true
    scheduleHealthCheck()
    workspaceController.show(moduleID: orderedMonitorIDs.first)
    publish(changedModuleID: nil)
    for (index, monitorID) in orderedMonitorIDs.enumerated() {
      guard !disabledModuleIDs.contains(monitorID) else { continue }
      let delay = MonitorRefreshPolicy.staggeredDelay(
        index: index,
        count: orderedMonitorIDs.count
      )
      monitorsByID[monitorID]?.start(after: delay)
    }
  }

  func scanNow(moduleID: String? = nil) {
    if let moduleID {
      guard !disabledModuleIDs.contains(moduleID) else { return }
      monitorsByID[moduleID]?.scanNow()
      return
    }
    for (index, monitorID) in orderedMonitorIDs.enumerated() {
      guard !disabledModuleIDs.contains(monitorID) else { continue }
      let delay = MonitorRefreshPolicy.staggeredDelay(
        index: index,
        count: orderedMonitorIDs.count
      )
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard self?.hasStarted == true else { return }
        self?.monitorsByID[monitorID]?.scanNow()
      }
    }
  }

  func showPlatformWindow(moduleID: String? = nil) {
    workspaceController.show(moduleID: moduleID)
  }

  func setMonitoringEnabled(_ enabled: Bool, moduleID: String) {
    guard let monitor = monitorsByID[moduleID], let current = snapshotsByID[moduleID] else { return }
    if enabled {
      guard disabledModuleIDs.remove(moduleID) != nil else { return }
      persistDisabledModuleIDs()
      let state = AppMonitorState.starting("监控已开启，正在连接平台")
      snapshotsByID[moduleID] = ModuleMonitorSnapshot(
        configuration: current.configuration,
        state: state,
        nextScanAt: nil
      )
      workspaceController.updateMonitorState(moduleID: moduleID, state: state)
      publish(changedModuleID: moduleID)
      if hasStarted { monitor.start() }
      return
    }

    guard disabledModuleIDs.insert(moduleID).inserted else { return }
    persistDisabledModuleIDs()
    monitor.stop()
    if hasStarted, workspaceController.selectedCredentialID == moduleID {
      monitor.startAuthenticationOnly()
    }
    snapshotsByID[moduleID] = ModuleMonitorSnapshot(
      configuration: current.configuration,
      state: .disabled,
      nextScanAt: nil
    )
    workspaceController.updateMonitorState(moduleID: moduleID, state: .disabled)
    publish(changedModuleID: moduleID)
  }

  private func persistDisabledModuleIDs() {
    UserDefaults.standard.set(
      disabledModuleIDs.sorted(),
      forKey: Self.disabledModuleIDsDefaultsKey
    )
  }

  func focusFind() {
    workspaceController.focusFind()
  }

  func stop() {
    healthCheckWorkItem?.cancel()
    healthCheckWorkItem = nil
    for monitor in monitorsByID.values {
      monitor.stop()
    }
    workspaceController.stopAll()
  }

  private func showSampleLimitSettings() {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "设置监控样本条数"
    alert.informativeText =
      "全部已登录后台将按这个数量统计。可设置 \(SampleLimitPolicy.minimumValue)–\(SampleLimitPolicy.maximumValue) 条，保存后立即重新扫描。"
    alert.addButton(withTitle: "保存并重扫")
    alert.addButton(withTitle: "取消")

    let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 36))
    let label = NSTextField(labelWithString: "最新")
    label.frame = NSRect(x: 18, y: 8, width: 42, height: 20)
    label.alignment = .right

    let field = NSTextField(frame: NSRect(x: 70, y: 4, width: 150, height: 28))
    field.integerValue = sampleLimit
    field.placeholderString = "200"
    field.setAccessibilityLabel("样本条数")

    let stepper = NSStepper(frame: NSRect(x: 224, y: 4, width: 20, height: 28))
    stepper.minValue = Double(SampleLimitPolicy.minimumValue)
    stepper.maxValue = Double(SampleLimitPolicy.maximumValue)
    stepper.increment = 10
    stepper.integerValue = sampleLimit

    let suffix = NSTextField(labelWithString: "条")
    suffix.frame = NSRect(x: 254, y: 8, width: 30, height: 20)

    stepper.target = field
    stepper.action = #selector(NSTextField.takeIntegerValueFrom(_:))
    accessory.addSubview(label)
    accessory.addSubview(field)
    accessory.addSubview(stepper)
    accessory.addSubview(suffix)
    alert.accessoryView = accessory

    alert.beginSheetModal(for: workspaceController.window) { [weak self] response in
      guard response == .alertFirstButtonReturn, let self else { return }
      let normalized = SampleLimitPolicy.normalize(field.integerValue)
      self.sampleLimit = normalized
      UserDefaults.standard.set(normalized, forKey: Self.sampleLimitDefaultsKey)
      self.workspaceController.updateSampleLimit(normalized)
      self.onSampleLimitChange?(normalized)
      for monitor in self.monitorsByID.values {
        monitor.updateSampleLimit(normalized)
      }
    }
  }

  private func showAutoLoginSettings(target: PlatformAutoLoginTarget) {
    let existing = credentialStore.profile(for: target.credentialID)

    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "\(target.displayName) 自动登录"
    alert.informativeText = "账号、密码、Google 密钥和 Token 只保存在本机加密文件中，不会上传数据库。"
    alert.addButton(withTitle: "保存")
    alert.addButton(withTitle: "删除配置")
    alert.addButton(withTitle: "取消")

    let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 174))
    let usernameField = NSTextField(frame: NSRect(x: 112, y: 138, width: 328, height: 26))
    usernameField.stringValue = existing?.username ?? ""
    usernameField.placeholderString = "后台账号"
    usernameField.setAccessibilityLabel("后台账号")

    let passwordField = NSSecureTextField(frame: NSRect(x: 112, y: 100, width: 328, height: 26))
    passwordField.stringValue = existing?.password ?? ""
    passwordField.placeholderString = "后台密码"
    passwordField.setAccessibilityLabel("后台密码")

    let totpField = NSSecureTextField(frame: NSRect(x: 112, y: 62, width: 328, height: 26))
    totpField.stringValue = existing?.totpSecret ?? ""
    totpField.placeholderString = "没有 Google 二次验证可留空"
    totpField.setAccessibilityLabel("Google 密钥")

    let enabledButton = NSButton(
      checkboxWithTitle: "Token 失效时自动登录并恢复监控",
      target: nil,
      action: nil
    )
    enabledButton.frame = NSRect(x: 112, y: 27, width: 328, height: 24)
    enabledButton.state = (existing?.autoLoginEnabled ?? true) ? .on : .off

    let tokenState = NSTextField(
      labelWithString: (existing?.token.isEmpty == false) ? "本地 Token：已保存" : "本地 Token：登录成功后自动保存"
    )
    tokenState.frame = NSRect(x: 112, y: 2, width: 328, height: 20)
    tokenState.textColor = .secondaryLabelColor
    tokenState.font = .systemFont(ofSize: 11)

    for (title, y) in [("账号", 142), ("密码", 104), ("Google 密钥", 66)] {
      let label = NSTextField(labelWithString: title)
      label.frame = NSRect(x: 0, y: CGFloat(y), width: 100, height: 20)
      label.alignment = .right
      accessory.addSubview(label)
    }
    accessory.addSubview(usernameField)
    accessory.addSubview(passwordField)
    accessory.addSubview(totpField)
    accessory.addSubview(enabledButton)
    accessory.addSubview(tokenState)
    alert.accessoryView = accessory

    alert.beginSheetModal(for: workspaceController.window) { [weak self] response in
      guard let self else { return }
      if response == .alertSecondButtonReturn {
        self.credentialStore.remove(moduleID: target.credentialID)
        self.notifyCredentialsDidChange(target)
        return
      }
      guard response == .alertFirstButtonReturn else { return }

      let username = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      let password = passwordField.stringValue
      guard !username.isEmpty, !password.isEmpty else {
        self.showCredentialError("账号和密码不能为空。")
        return
      }
      let totpSecret = totpField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard totpSecret.isEmpty || TOTPSecretPolicy.isValid(totpSecret) else {
        self.showCredentialError(
          "Google 密钥格式无效。请填写原始 Base32 密钥或完整 otpauth:// 链接，不能填写动态验证码或其他文字。"
        )
        return
      }
      let profile = LocalLoginProfile(
        username: username,
        password: password,
        totpSecret: totpSecret,
        token: existing?.username == username ? (existing?.token ?? "") : "",
        autoLoginEnabled: enabledButton.state == .on
      )
      guard
        self.credentialStore.save(profile, for: target.credentialID),
        self.credentialStore.profile(for: target.credentialID) == profile
      else {
        self.showCredentialError("无法写入或读取本机加密配置文件，请检查应用数据目录权限。")
        return
      }
      self.notifyCredentialsDidChange(target)
    }
  }

  private func notifyCredentialsDidChange(_ target: PlatformAutoLoginTarget) {
    monitorsByID[target.credentialID]?.credentialsDidChange()
  }

  private func showCredentialError(_ message: String) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "自动登录配置未保存"
    alert.informativeText = message
    alert.addButton(withTitle: "知道了")
    alert.beginSheetModal(for: workspaceController.window)
  }

  private func handle(
    configuration: MonitorConfiguration,
    state: AppMonitorState,
    nextScanAt: Date?
  ) {
    guard !disabledModuleIDs.contains(configuration.id) else { return }
    snapshotsByID[configuration.id] = ModuleMonitorSnapshot(
      configuration: configuration,
      state: state,
      nextScanAt: nextScanAt,
      dailyFinancialMetrics: monitorsByID[configuration.id]?.latestDailyFinancialMetrics
    )
    workspaceController.updateMonitorState(moduleID: configuration.id, state: state)
    publish(changedModuleID: configuration.id)
  }

  private func publish(changedModuleID: String?) {
    let staleMonitorIDs = expireStaleResults()
    let modules = orderedMonitorIDs.compactMap { snapshotsByID[$0] }
    onStateChange?(FleetMonitorSnapshot(modules: modules), changedModuleID)
    guard !staleMonitorIDs.isEmpty else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      for monitorID in staleMonitorIDs {
        self.monitorsByID[monitorID]?.scanNow()
      }
    }
  }

  private func expireStaleResults(now: Date = Date()) -> [String] {
    var staleMonitorIDs: [String] = []
    for monitorID in orderedMonitorIDs {
      guard let snapshot = snapshotsByID[monitorID],
        snapshot.state.metrics != nil,
        let scannedAt = snapshot.state.scannedAt,
        MonitorRefreshPolicy.resultIsStale(
          scannedAt: scannedAt,
          now: now,
          scanInterval: snapshot.configuration.scanInterval
        )
      else { continue }

      let staleMinutes = Int(
        ceil(MonitorRefreshPolicy.staleAge(
          scanInterval: snapshot.configuration.scanInterval
        ) / 60)
      )
      let expiredState = AppMonitorState.error(
        "监控结果已超过 \(staleMinutes) 分钟未更新，正在重新扫描。",
        scannedAt
      )
      snapshotsByID[monitorID] = ModuleMonitorSnapshot(
        configuration: snapshot.configuration,
        state: expiredState,
        nextScanAt: nil
      )
      workspaceController.updateMonitorState(moduleID: monitorID, state: expiredState)
      staleMonitorIDs.append(monitorID)
    }
    return staleMonitorIDs
  }

  private func scheduleHealthCheck() {
    healthCheckWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.healthCheckWorkItem = nil
      self.publish(changedModuleID: nil)
      self.scheduleHealthCheck()
    }
    healthCheckWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: item)
  }

  private func bind(_ monitor: ModuleMonitorController) {
    monitor.onStateChange = { [weak self, weak monitor] state, nextScanAt in
      guard let self, let monitor else { return }
      self.handle(
        configuration: monitor.configuration,
        state: state,
        nextScanAt: nextScanAt
      )
    }
  }

  private func configuration(for page: PlatformPageDescriptor) -> MonitorConfiguration {
    MonitorConfiguration(
      id: page.credentialID,
      displayName: page.displayName,
      targetURL: page.startURL,
      profileIdentifier: monitorsByID[page.credentialID]?.configuration.profileIdentifier
        ?? page.profileIdentifier,
      sampleLimit: sampleLimit,
      scanInterval: 60,
      alertThreshold: 0.50
    )
  }

  private func registerPage(_ page: PlatformPageDescriptor) {
    guard monitorsByID[page.credentialID] == nil else {
      updatePage(page)
      return
    }

    let pageConfiguration = configuration(for: page)
    let monitor = ModuleMonitorController(
      configuration: pageConfiguration,
      sampleLimit: sampleLimit,
      credentialStore: credentialStore,
      automationRuntime: automationRuntime,
      loginAutomation: loginAutomation,
      webView: page.webView
    )
    bind(monitor)
    monitorsByID[page.credentialID] = monitor
    orderedMonitorIDs.append(page.credentialID)
    snapshotsByID[page.credentialID] = ModuleMonitorSnapshot(
      configuration: pageConfiguration,
      state: disabledModuleIDs.contains(page.credentialID) ? .disabled : .starting("等待连接"),
      nextScanAt: nil
    )
    workspaceController.updateMonitorState(
      moduleID: page.credentialID,
      state: disabledModuleIDs.contains(page.credentialID) ? .disabled : .starting("等待连接")
    )
    workspaceController.refreshMonitorCount()
    publish(changedModuleID: nil)
    if hasStarted, !disabledModuleIDs.contains(page.credentialID) {
      let index = orderedMonitorIDs.firstIndex(of: page.credentialID) ?? 0
      monitor.start(
        after: MonitorRefreshPolicy.staggeredDelay(
          index: index,
          count: orderedMonitorIDs.count
        )
      )
    }
    monitor.setPageActive(workspaceController.selectedCredentialID == page.credentialID)
  }

  private func applyActivePage(_ credentialID: String?) {
    for (monitorID, monitor) in monitorsByID {
      let active = monitorID == credentialID
      if hasStarted, disabledModuleIDs.contains(monitorID) {
        if active {
          monitor.startAuthenticationOnly()
        } else {
          monitor.stopAuthenticationOnly()
        }
      }
      monitor.setPageActive(active)
    }
  }

  private func updatePage(_ page: PlatformPageDescriptor) {
    guard let monitor = monitorsByID[page.credentialID] else {
      registerPage(page)
      return
    }
    let pageConfiguration = configuration(for: page)
    let targetChanged = monitor.configuration.targetURL != pageConfiguration.targetURL
    monitor.updateConfiguration(pageConfiguration)
    if let current = snapshotsByID[page.credentialID] {
      snapshotsByID[page.credentialID] = ModuleMonitorSnapshot(
        configuration: pageConfiguration,
        state: targetChanged ? .starting("后台地址已更新，正在重新连接") : current.state,
        nextScanAt: targetChanged ? nil : current.nextScanAt,
        dailyFinancialMetrics: targetChanged ? nil : current.dailyFinancialMetrics
      )
    }
    workspaceController.updateMonitorState(
      moduleID: page.credentialID,
      state: snapshotsByID[page.credentialID]?.state ?? .starting("等待连接")
    )
    publish(changedModuleID: page.credentialID)
  }

  private func removePage(credentialID: String) {
    monitorsByID.removeValue(forKey: credentialID)?.stop()
    orderedMonitorIDs.removeAll { $0 == credentialID }
    snapshotsByID.removeValue(forKey: credentialID)
    if disabledModuleIDs.remove(credentialID) != nil { persistDisabledModuleIDs() }
    workspaceController.refreshMonitorCount()
    publish(changedModuleID: nil)
  }

  private func applyPageOrder(_ credentialIDs: [String]) {
    let active = Set(monitorsByID.keys)
    orderedMonitorIDs = credentialIDs.filter { active.contains($0) }
    publish(changedModuleID: nil)
  }
}
