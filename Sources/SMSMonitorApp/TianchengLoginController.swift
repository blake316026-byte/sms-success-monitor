import Foundation
import OSLog
import WebKit

final class TianchengLoginController {
  private static let logger = Logger(subsystem: "com.local.sms-success-monitor.public", category: "Authentication")
  private static let source: String = {
    ["tiancheng-login.js", "tiancheng-session.js"].compactMap { name in
      guard let url = Bundle.main.resourceURL?.appendingPathComponent("auto-login/" + name) else { return nil as String? }
      return try? String(contentsOf: url, encoding: .utf8)
    }.joined(separator: "\n")
  }()

  static func detect(in webView: WKWebView, completion: @escaping (Bool?) -> Void) {
    guard !source.isEmpty else { completion(nil); return }
    let detection = """
      \(source)
      if (globalThis.smsTianchengLogin.detect()) return true;
      if (document.readyState === 'loading' || !document.body || !document.body.childElementCount) return null;
      return false;
      """
    webView.callAsyncJavaScript(detection,
      arguments: [:], in: nil, in: .page) { result in
      completion((try? result.get()) as? Bool)
    }
  }

  private weak var webView: WKWebView?
  private let origin: URL
  private let credentialID: String
  private let store: LocalCredentialStore
  private let runtime: LocalAutomationRuntime
  private let onState: (AppMonitorState) -> Void
  private let isPageActive: () -> Bool
  private var workItem: DispatchWorkItem?
  private var generation = UUID()
  private var running = false
  private var busy = false
  private var stage = ""
  private var submittedAt: Date?
  private var preparationStartedAt: Date?
  private var callID: UUID?
  private var callTimeout: DispatchWorkItem?
  private var lastKind = ""
  private var lastSessionKind = ""
  private(set) var isPausedForManualAuthentication = false
  private(set) var isAuthenticationInProgress = false

  var canSuspendForMemory: Bool {
    running && !busy && !isAuthenticationInProgress && !isPausedForManualAuthentication && stage.isEmpty
  }

  init(webView: WKWebView, origin: URL, credentialID: String,
    store: LocalCredentialStore, runtime: LocalAutomationRuntime,
    isPageActive: @escaping () -> Bool = { false },
    onState: @escaping (AppMonitorState) -> Void) {
    self.webView = webView
    self.origin = origin
    self.credentialID = credentialID
    self.store = store
    self.runtime = runtime
    self.onState = onState
    self.isPageActive = isPageActive
  }

  func start() {
    guard !running else { return }
    running = true
    poll()
  }

  func stop() {
    running = false
    generation = UUID()
    workItem?.cancel()
    busy = false
    callTimeout?.cancel()
    callTimeout = nil
    callID = nil
    isAuthenticationInProgress = false
  }

  func attach(to webView: WKWebView) {
    self.webView = webView
  }

  func credentialsDidChange() {
    stop()
    running = true
    stage = ""
    submittedAt = nil
    preparationStartedAt = nil
    isPausedForManualAuthentication = false
    call("reset()") { [weak self] _ in
      self?.call("reset()", session: true) { [weak self] _ in self?.poll() }
    }
  }

  private var hasMatchingOrigin: Bool {
    guard let url = webView?.url else { return false }
    return url.scheme == origin.scheme && url.host == origin.host && url.port == origin.port
  }

  private func call(_ action: String, arguments: [String: Any] = [:], session: Bool = false, completion: @escaping (Any?) -> Void) {
    guard running else { return }
    guard hasMatchingOrigin, let webView else { completion(nil); return }
    let epoch = generation
    let id = UUID()
    callID = id
    let timeout = DispatchWorkItem { [weak self] in
      guard let self, self.running, self.generation == epoch, self.callID == id else { return }
      self.callID = nil
      self.callTimeout = nil
      Self.logger.notice("Tiancheng page operation timed out for \(self.credentialID, privacy: .public)")
      completion(nil)
    }
    callTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    let adapter = session ? "smsTianchengSession" : "smsTianchengLogin"
    webView.callAsyncJavaScript("\(Self.source)\nreturn await globalThis.\(adapter).\(action);",
      arguments: arguments, in: nil, in: .page) { [weak self] result in
      guard let self, self.running, self.generation == epoch, self.callID == id else { return }
      self.callID = nil
      self.callTimeout?.cancel()
      self.callTimeout = nil
      completion(self.hasMatchingOrigin ? try? result.get() : nil)
    }
  }

  private func schedule(after delay: TimeInterval = 3) {
    busy = false
    workItem?.cancel()
    let item = DispatchWorkItem { [weak self] in self?.poll() }
    workItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
  }

  private func poll() {
    guard running, !busy else { return }
    guard hasMatchingOrigin else { schedule(after: 10); return }
    busy = true
    call("snapshot()") { [weak self] value in
      guard let self else { return }
      let kind = (value as? [String: Any])?["kind"] as? String ?? "waiting"
      let safeKind = ["authenticated", "manual", "password", "totp", "waiting", "unknown"].contains(kind) ? kind : "unknown"
      if safeKind != self.lastKind {
        self.lastKind = safeKind
        Self.logger.notice("Tiancheng login state for \(self.credentialID, privacy: .public): \(safeKind, privacy: .public)")
      }
      if kind == "authenticated" {
        self.checkSessionVerification()
        return
      }
      if kind == "manual" {
        self.isPausedForManualAuthentication = true
        self.isAuthenticationInProgress = false
        self.onState(.authenticationRequired("天成自动登录已暂停，请检查登录页或保存配置后重试；不会自动绑定 Google 或修改密码"))
        self.schedule(after: 10)
        return
      }
      guard let profile = self.store.profile(for: self.credentialID), profile.canAutoLogin else {
        self.isAuthenticationInProgress = false
        self.onState(.authenticationRequired("请配置天成自动登录账号、密码和 Google 密钥"))
        self.schedule(after: 10)
        return
      }
      if self.isPausedForManualAuthentication {
        self.schedule(after: 10)
        return
      }
      if kind == "totp", self.stage != "totp" {
        self.submitTOTP(profile)
      } else if kind == "password", self.stage.isEmpty {
        self.submitPassword(profile)
      } else if let submittedAt = self.submittedAt, Date().timeIntervalSince(submittedAt) > 20 {
        self.pause("天成登录未通过，已停止自动重试以避免锁号，请检查账号或 Google 密钥后保存配置重试")
      } else {
        self.schedule()
      }
    }
  }

  private func authenticated() {
    isPausedForManualAuthentication = false
    isAuthenticationInProgress = false
    stage = ""
    submittedAt = nil
    preparationStartedAt = nil
    onState(.browserOnly("天成已登录"))
    schedule(after: 10)
  }

  private func checkSessionVerification() {
    guard let profile = store.profile(for: credentialID), profile.canAutoLogin else { authenticated(); return }
    // Optional local canary scope. It does not change stored accounts or backend policy.
    let canary = UserDefaults.standard.stringArray(forKey: "SMSMonitor.TianchengSessionCanary.v1") ?? []
    guard canary.isEmpty || canary.contains(credentialID) else { authenticated(); return }
    call("snapshot({ username })", arguments: ["username": profile.username], session: true) { [weak self] value in
      guard let self else { return }
      guard self.store.profile(for: self.credentialID) == profile else { self.schedule(); return }
      let payload = value as? [String: Any], kind = payload?["kind"] as? String ?? "unavailable"
      let safeKind = ["none", "verified", "required", "operation", "manual", "waiting", "unavailable"].contains(kind) ? kind : "unavailable"
      if self.lastSessionKind != safeKind {
        self.lastSessionKind = safeKind
        Self.logger.notice("Tiancheng periodic GA state for \(self.credentialID, privacy: .public): \(safeKind, privacy: .public); active=\(self.isPageActive())")
        if kind == "required" {
          let fixed = payload?["fixedMinutes"] as? Int ?? -1, idle = payload?["idleMinutes"] as? Int ?? -1
          Self.logger.notice("Tiancheng periodic GA policy for \(self.credentialID, privacy: .public): fixedMinutes=\(fixed) idleMinutes=\(idle)")
        }
        if let reason = payload?["reason"] as? String, ["identity", "status", "policy", "read-error"].contains(reason) {
          Self.logger.notice("Tiancheng periodic GA read unavailable for \(self.credentialID, privacy: .public): \(reason, privacy: .public)")
        }
        if let shapes = payload?["shapes"] as? [[String: Any]] {
          for shape in shapes.prefix(3) {
            let z = shape["z"] as? Int ?? -1, inputs = shape["inputs"] as? Int ?? -1, buttons = shape["buttons"] as? Int ?? -1
            let ga = shape["gaHint"] as? Bool ?? false, minutes = shape["minuteHint"] as? Bool ?? false
            Self.logger.notice("Tiancheng periodic GA shape for \(self.credentialID, privacy: .public): z=\(z) inputs=\(inputs) buttons=\(buttons) gaHint=\(ga) minuteHint=\(minutes)")
          }
        }
      }
      switch kind {
      case "none", "verified":
        if kind == "verified" {
          Self.logger.notice("Tiancheng periodic GA verified by status readback for \(self.credentialID, privacy: .public)")
        }
        self.authenticated()
      case "required":
        guard let challenge = payload?["challenge"] as? String, !profile.totpSecret.isEmpty else {
          self.isAuthenticationInProgress = false
          self.onState(.authenticationRequired("天成定期身份验证需要 Google 密钥，请检查自动登录配置"))
          self.schedule(after: 10); return
        }
        self.submitSessionTOTP(profile, challenge: challenge)
      case "operation":
        self.isAuthenticationInProgress = false
        self.onState(.authenticationRequired("天成操作验证待人工确认；不会自动重试支付或配置操作"))
        self.schedule(after: 10)
      case "manual":
        self.isAuthenticationInProgress = false
        self.onState(.authenticationRequired("天成定期验证已暂停：人工输入、验证错误或结果未确认，请检查弹窗；不会自动重试"))
        self.schedule(after: 10)
      case "waiting":
        self.isAuthenticationInProgress = true
        self.onState(.starting("天成：等待定期身份验证完成并回读"))
        self.schedule()
      default:
        self.isAuthenticationInProgress = false
        self.onState(.authenticationRequired("天成定期验证状态暂不可确认，未提交验证码"))
        self.schedule(after: 30)
      }
    }
  }

  private func submitSessionTOTP(_ profile: LocalLoginProfile, challenge: String) {
    isAuthenticationInProgress = true
    let cycle = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 30)
    if cycle > 22 { schedule(after: 31 - cycle); return }
    let epoch = generation
    onState(.starting("天成：正在完成定期 Google 身份验证"))
    runtime.generateCurrentTOTP(secret: profile.totpSecret) { [weak self] result in
      guard let self, self.running, self.generation == epoch else { return }
      guard self.hasMatchingOrigin, self.store.profile(for: self.credentialID) == profile else { self.schedule(); return }
      guard case .success(let code) = result else {
        self.onState(.authenticationRequired("天成定期动态码生成失败，请检查本地密钥"))
        self.isAuthenticationInProgress = false
        self.schedule(after: 30); return
      }
      self.call("submit({ username, code, challengeID })", arguments: ["username":profile.username, "code":code, "challengeID":challenge], session: true) { [weak self] value in
        guard let self else { return }
        if (value as? [String:Any])?["submitted"] as? Bool == true {
          Self.logger.notice("Tiancheng periodic GA submitted for \(self.credentialID, privacy: .public); active=\(self.isPageActive())")
        }
        // The page adapter persists a pre-click marker and only reads after an uncertain submission.
        self.schedule()
      }
    }
  }

  private func submitPassword(_ profile: LocalLoginProfile) {
    isAuthenticationInProgress = true
    onState(.starting("天成：正在切换密码登录并提交账号密码"))
    call("submitPassword({ username, password })", arguments: ["username": profile.username, "password": profile.password]) { [weak self] value in
      self?.finishSubmission(value, stage: "password")
    }
  }

  private func submitTOTP(_ profile: LocalLoginProfile) {
    isAuthenticationInProgress = true
    guard !profile.totpSecret.isEmpty else {
      onState(.authenticationRequired("天成密码步骤已完成，请在自动登录配置中填写 Google 密钥，或人工输入动态码"))
      schedule(after: 10)
      return
    }
    let epoch = generation
    let cycle = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 30)
    if cycle > 24 { schedule(after: 31 - cycle); return }
    onState(.starting("天成：正在提交 Google 动态码"))
    runtime.generateCurrentTOTP(secret: profile.totpSecret) { [weak self] result in
      guard let self, self.running, self.generation == epoch else { return }
      guard self.hasMatchingOrigin else { self.schedule(); return }
      guard case .success(let code) = result else {
        self.pause("天成 Google 动态码生成失败，请检查本地密钥及识别组件后重试")
        return
      }
      self.call("submitTotp({ code })", arguments: ["code": code]) { [weak self] value in
        self?.finishSubmission(value, stage: "totp")
      }
    }
  }

  private func finishSubmission(_ value: Any?, stage: String) {
    let payload = value as? [String: Any]
    if payload?["submitted"] as? Bool == false, payload?["retryable"] as? Bool == true {
      // Only the page's explicit pre-click result is safe to retry. A lost
      // callback may already have submitted credentials and is not replayed.
      let started = preparationStartedAt ?? Date()
      preparationStartedAt = started
      let deferred = Date().timeIntervalSince(started) > 30
      if deferred {
        preparationStartedAt = nil
        isAuthenticationInProgress = false
      }
      onState(.starting("天成登录表单尚未就绪，正在等待页面完成加载"))
      schedule(after: deferred ? 30 : 3)
      return
    }
    guard (value as? [String: Any])?["submitted"] as? Bool == true else {
      pause("天成登录提交结果未确认或检测到人工接管，已暂停；请检查登录页后重试")
      return
    }
    preparationStartedAt = nil
    self.stage = stage
    submittedAt = Date()
    Self.logger.notice("Tiancheng login submitted for \(self.credentialID, privacy: .public); stage=\(stage, privacy: .public)")
    schedule()
  }

  private func pause(_ message: String) {
    isPausedForManualAuthentication = true
    isAuthenticationInProgress = false
    Self.logger.notice("Tiancheng login paused for \(self.credentialID, privacy: .public); stage=\(self.stage, privacy: .public)")
    call("pause()") { [weak self] _ in
      self?.onState(.authenticationRequired(message))
      self?.schedule(after: 10)
    }
  }
}
