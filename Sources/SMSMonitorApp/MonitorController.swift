import AppKit
import Foundation
import SMSMonitorCore
import WebKit

private final class ModuleMonitorController: NSObject, WKNavigationDelegate {
  let configuration: MonitorConfiguration
  let webView: WKWebView
  var onStateChange: ((AppMonitorState, Date?) -> Void)?

  private static let maximumAutoLoginAttempts = 5
  private static let autoLoginCooldown: TimeInterval = 5 * 60

  private let credentialStore: LocalCredentialStore
  private let automationRuntime: LocalAutomationRuntime
  private let loginAutomation: LoginPageAutomation
  private var nextScanTimer: Timer?
  private var nextScanAt: Date?
  private var isScanning = false
  private var lastMetrics: ScanMetrics?
  private var needsImmediateScan = true
  private var consecutiveScanFailures = 0
  private var autoLoginAttempts = 0
  private var autoLoginInProgress = false
  private var autoLoginStage = ""
  private var autoLoginCooldownUntil: Date?
  private var autoLoginOutcomeWorkItem: DispatchWorkItem?
  private var mockScenario: String?

  init(
    configuration: MonitorConfiguration,
    credentialStore: LocalCredentialStore,
    automationRuntime: LocalAutomationRuntime,
    loginAutomation: LoginPageAutomation
  ) {
    self.configuration = configuration
    self.credentialStore = credentialStore
    self.automationRuntime = automationRuntime
    self.loginAutomation = loginAutomation

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
    autoLoginOutcomeWorkItem?.cancel()
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
      handleAuthenticationRequired("平台登录已失效。")
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
          sampleLimit: configuration.sampleLimit
        )
        guard metrics.sampleCount > 0 else {
          handleScanFailure("短信记录接口未返回可统计的记录。")
          return
        }

        consecutiveScanFailures = 0
        lastMetrics = metrics
        let scannedAt = Date()
        if metrics.shouldAlert(threshold: configuration.alertThreshold) {
          emit(.alert(metrics, scannedAt), nextScanAt: nextScanAt)
        } else {
          emit(.healthy(metrics, scannedAt), nextScanAt: nextScanAt)
        }

      case "auth":
        let message = payload["message"] as? String ?? "平台登录已失效。"
        handleAuthenticationRequired(message)

      default:
        let message = payload["message"] as? String ?? "短信记录接口扫描失败。"
        handleScanFailure(message)
      }
    }
  }

  private func handleScanFailure(_ message: String) {
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

  func credentialsDidChange() {
    autoLoginAttempts = 0
    autoLoginCooldownUntil = nil
    autoLoginInProgress = false
    autoLoginStage = ""
    autoLoginOutcomeWorkItem?.cancel()
    persistCurrentToken()
    guard let currentURL = webView.url, requiresAuthentication(currentURL) else { return }
    handleAuthenticationRequired("自动登录配置已更新。")
  }

  private func handleAuthenticationRequired(_ message: String) {
    isScanning = false
    consecutiveScanFailures = 0
    needsImmediateScan = true
    scheduleNextScan(after: configuration.scanInterval)

    guard let profile = credentialStore.profile(for: configuration.id), profile.canAutoLogin else {
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
      autoLoginAttempts = 0
      autoLoginCooldownUntil = nil
    }

    emit(.starting("Token 已失效，正在自动登录"), nextScanAt: nextScanAt)
    if let currentURL = webView.url, requiresAuthentication(currentURL) {
      attemptAutoLogin(profile: profile, url: currentURL)
    } else {
      webView.load(URLRequest(url: loginURL))
    }
  }

  private func attemptAutoLogin(profile: LocalLoginProfile, url: URL) {
    guard !autoLoginInProgress else { return }
    guard profile.canAutoLogin else {
      emit(.authenticationRequired("请先配置本后台的自动登录账号。"), nextScanAt: nextScanAt)
      return
    }
    if url.path == "/unlock-ip" {
      emit(.authenticationRequired("平台要求人工完成 IP 解锁，自动登录已暂停。"), nextScanAt: nextScanAt)
      return
    }
    guard autoLoginAttempts < Self.maximumAutoLoginAttempts else {
      pauseAutoLogin()
      return
    }

    autoLoginInProgress = true
    emit(
      .starting("正在自动登录（\(autoLoginAttempts + 1)/\(Self.maximumAutoLoginAttempts)）"),
      nextScanAt: nextScanAt
    )
    loginAutomation.snapshot(in: webView) { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        self.retryAutoLogin("无法读取登录页面：\(error.localizedDescription)")
      case .success(let snapshot):
        if !snapshot.token.isEmpty {
          self.credentialStore.updateToken(snapshot.token, for: self.configuration.id)
        }
        switch snapshot.kind {
        case "login":
          self.solveCaptchaAndSubmit(profile: profile, dataURL: snapshot.captchaDataURL)
        case "totp":
          self.generateAndSubmitTOTP(profile: profile)
        case "authenticated":
          self.completeAutoLogin(token: snapshot.token)
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
    automationRuntime.recognize(dataURL: dataURL) { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        self.retryAutoLogin("本地验证码识别失败：\(error.localizedDescription)")
      case .success(let captcha):
        guard (4...8).contains(captcha.count) else {
          self.loginAutomation.refreshCaptcha(in: self.webView)
          self.retryAutoLogin("本地验证码识别结果无效")
          return
        }
        self.loginAutomation.submitLogin(
          in: self.webView,
          profile: profile,
          captcha: captcha
        ) { [weak self] submitResult in
          guard let self else { return }
          guard (try? submitResult.get()) == true else {
            self.retryAutoLogin("登录表单尚未准备完成")
            return
          }
          self.autoLoginStage = "login"
          self.scheduleAutoLoginOutcomeCheck()
        }
      }
    }
  }

  private func generateAndSubmitTOTP(profile: LocalLoginProfile) {
    let secret = profile.totpSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !secret.isEmpty else {
      autoLoginInProgress = false
      emit(
        .authenticationRequired("账号密码已通过，但本地未配置 Google 密钥，请人工完成二次验证。"),
        nextScanAt: nextScanAt
      )
      return
    }
    let offsets = [0, -210, 210, -180, 180]
    let offset = offsets[min(autoLoginAttempts, offsets.count - 1)]
    let adjustedNow = Date().addingTimeInterval(TimeInterval(offset))
    let cyclePosition = adjustedNow.timeIntervalSince1970.truncatingRemainder(dividingBy: 30)
    let delay = cyclePosition > 24 ? 6.5 : 0
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      guard self.autoLoginInProgress else { return }
      let timestamp = Date().addingTimeInterval(TimeInterval(offset))
      self.automationRuntime.generateTOTP(secret: secret, timestamp: timestamp) { [weak self] result in
        guard let self else { return }
        switch result {
        case .failure(let error):
          self.retryAutoLogin("Google 动态码生成失败：\(error.localizedDescription)")
        case .success(let code):
          self.loginAutomation.submitTOTP(in: self.webView, code: code) { [weak self] submitResult in
            guard let self else { return }
            guard (try? submitResult.get()) == true else {
              self.retryAutoLogin("Google 验证页面尚未准备完成")
              return
            }
            self.autoLoginStage = "totp"
            self.scheduleAutoLoginOutcomeCheck()
          }
        }
      }
    }
  }

  private func scheduleAutoLoginOutcomeCheck() {
    autoLoginOutcomeWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
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
      self.completeAutoLogin(token: "")
    }
    autoLoginOutcomeWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: item)
  }

  private func retryAutoLogin(_ message: String) {
    autoLoginInProgress = false
    autoLoginStage = ""
    autoLoginAttempts += 1
    guard autoLoginAttempts < Self.maximumAutoLoginAttempts else {
      pauseAutoLogin(detail: message)
      return
    }
    emit(.starting("\(message)，稍后自动重试"), nextScanAt: nextScanAt)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      guard let self, let currentURL = self.webView.url,
        let profile = self.credentialStore.profile(for: self.configuration.id)
      else { return }
      self.attemptAutoLogin(profile: profile, url: currentURL)
    }
  }

  private func pauseAutoLogin(detail: String = "") {
    autoLoginInProgress = false
    autoLoginStage = ""
    let cooldown = Date().addingTimeInterval(Self.autoLoginCooldown)
    autoLoginCooldownUntil = cooldown
    let suffix = detail.isEmpty ? "" : "（\(detail)）"
    emit(
      .authenticationRequired(
        "自动登录已连续失败 \(Self.maximumAutoLoginAttempts) 次\(suffix)，暂停至 \(Self.timeText(cooldown))。"
      ),
      nextScanAt: nextScanAt
    )
  }

  private func completeAutoLogin(token: String) {
    autoLoginInProgress = false
    autoLoginStage = ""
    autoLoginAttempts = 0
    autoLoginCooldownUntil = nil
    autoLoginOutcomeWorkItem?.cancel()
    needsImmediateScan = true
    if !token.isEmpty {
      credentialStore.updateToken(token, for: configuration.id)
    }
    persistCurrentToken()
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
    guard credentialStore.profile(for: configuration.id) != nil else { return }
    loginAutomation.extractToken(in: webView) { [weak self] token in
      guard let self else { return }
      if !token.isEmpty {
        self.credentialStore.updateToken(token, for: self.configuration.id)
        return
      }
      self.persistCookieToken()
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

  private static func timeText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
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
      handleAuthenticationRequired("平台需要重新登录。")
      return
    }

    guard isMonitorOrigin(url) else { return }
    autoLoginInProgress = false
    autoLoginStage = ""
    autoLoginAttempts = 0
    autoLoginCooldownUntil = nil
    autoLoginOutcomeWorkItem?.cancel()
    persistCurrentToken()
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
    isScanning = false
    needsImmediateScan = true
    handleScanFailure("平台页面加载失败：\(error.localizedDescription)")
    scheduleNextScan(after: configuration.scanInterval)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    isScanning = false
    autoLoginInProgress = false
    autoLoginStage = ""
    autoLoginOutcomeWorkItem?.cancel()
    consecutiveScanFailures = 0
    needsImmediateScan = true
    emit(.error("平台页面进程已重启，正在恢复。", Date()), nextScanAt: nextScanAt)
    webView.reload()
  }
}

final class MonitorController {
  let configurations: [MonitorConfiguration]
  var onStateChange: ((FleetMonitorSnapshot, String?) -> Void)?

  private let credentialStore: LocalCredentialStore
  private let monitors: [ModuleMonitorController]
  private let workspaceController: PlatformWorkspaceController
  private var snapshotsByID: [String: ModuleMonitorSnapshot]
  private var activityToken: NSObjectProtocol?

  init(configurations: [MonitorConfiguration]) {
    self.configurations = configurations

    let credentialStore = LocalCredentialStore()
    let automationRuntime = LocalAutomationRuntime()
    let loginAutomation = LoginPageAutomation()
    self.credentialStore = credentialStore
    let monitors = configurations.map {
      ModuleMonitorController(
        configuration: $0,
        credentialStore: credentialStore,
        automationRuntime: automationRuntime,
        loginAutomation: loginAutomation
      )
    }
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
    self.workspaceController.onAutoLoginSettings = { [weak self] moduleID in
      self?.showAutoLoginSettings(moduleID: moduleID)
    }

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

  private func showAutoLoginSettings(moduleID: String) {
    guard let configuration = configurations.first(where: { $0.id == moduleID }) else { return }
    let existing = credentialStore.profile(for: moduleID)

    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "\(configuration.displayName) 自动登录"
    alert.informativeText = "账号、密码、Google 密钥和 Token 只保存在本机钥匙串，不会上传数据库。"
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
        self.credentialStore.remove(moduleID: moduleID)
        self.monitors.first { $0.configuration.id == moduleID }?.credentialsDidChange()
        return
      }
      guard response == .alertFirstButtonReturn else { return }

      let username = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      let password = passwordField.stringValue
      guard !username.isEmpty, !password.isEmpty else {
        self.showCredentialError("账号和密码不能为空。")
        return
      }
      let profile = LocalLoginProfile(
        username: username,
        password: password,
        totpSecret: totpField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
        token: existing?.token ?? "",
        autoLoginEnabled: enabledButton.state == .on
      )
      guard self.credentialStore.save(profile, for: moduleID) else {
        self.showCredentialError("无法写入本机钥匙串，请检查系统钥匙串权限。")
        return
      }
      self.monitors.first { $0.configuration.id == moduleID }?.credentialsDidChange()
    }
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
