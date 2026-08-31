import Foundation
import WebKit

final class TianchengLoginController {
  private static let source: String = {
    let url = Bundle.main.resourceURL?.appendingPathComponent("auto-login/tiancheng-login.js")
    return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
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
  private var workItem: DispatchWorkItem?
  private var generation = UUID()
  private var running = false
  private var busy = false
  private var stage = ""
  private var submittedAt: Date?

  init(webView: WKWebView, origin: URL, credentialID: String,
    store: LocalCredentialStore, runtime: LocalAutomationRuntime,
    onState: @escaping (AppMonitorState) -> Void) {
    self.webView = webView
    self.origin = origin
    self.credentialID = credentialID
    self.store = store
    self.runtime = runtime
    self.onState = onState
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
  }

  func credentialsDidChange() {
    stop()
    running = true
    stage = ""
    submittedAt = nil
    call("reset()") { [weak self] _ in self?.poll() }
  }

  private var hasMatchingOrigin: Bool {
    guard let url = webView?.url else { return false }
    return url.scheme == origin.scheme && url.host == origin.host && url.port == origin.port
  }

  private func call(_ action: String, arguments: [String: Any] = [:], completion: @escaping (Any?) -> Void) {
    guard running, hasMatchingOrigin, let webView else { return }
    let epoch = generation
    webView.callAsyncJavaScript("\(Self.source)\nreturn await globalThis.smsTianchengLogin.\(action);",
      arguments: arguments, in: nil, in: .page) { [weak self] result in
      guard let self, self.running, self.generation == epoch, self.hasMatchingOrigin else { return }
      completion(try? result.get())
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
      if kind == "authenticated" {
        self.stage = ""
        self.submittedAt = nil
        self.onState(.browserOnly("天成已登录；短信与财务接口尚未接入，不发送监控请求"))
        self.schedule(after: 10)
        return
      }
      if kind == "manual" {
        self.onState(.authenticationRequired("天成自动登录已暂停，请检查登录页或保存配置后重试；不会自动绑定 Google 或修改密码"))
        self.schedule(after: 10)
        return
      }
      guard let profile = self.store.profile(for: self.credentialID), profile.canAutoLogin else {
        self.onState(.authenticationRequired("请配置天成自动登录账号、密码和 Google 密钥"))
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

  private func submitPassword(_ profile: LocalLoginProfile) {
    onState(.starting("天成：正在切换密码登录并提交账号密码"))
    call("submitPassword({ username, password })", arguments: ["username": profile.username, "password": profile.password]) { [weak self] value in
      self?.finishSubmission(value, stage: "password")
    }
  }

  private func submitTOTP(_ profile: LocalLoginProfile) {
    guard !profile.totpSecret.isEmpty else {
      onState(.authenticationRequired("天成密码步骤已完成，请在自动登录配置中填写 Google 密钥，或人工输入动态码"))
      schedule(after: 10)
      return
    }
    let epoch = generation
    let cycle = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 30)
    if cycle > 24 { schedule(after: 31 - cycle); return }
    onState(.starting("天成：正在提交 Google 动态码"))
    runtime.generateTOTP(secret: profile.totpSecret, timestamp: Date()) { [weak self] result in
      guard let self, self.running, self.generation == epoch, self.hasMatchingOrigin else { return }
      guard case .success(let code) = result else {
        self.pause("天成 Google 密钥格式无效，请检查配置")
        return
      }
      self.call("submitTotp({ code })", arguments: ["code": code]) { [weak self] value in
        self?.finishSubmission(value, stage: "totp")
      }
    }
  }

  private func finishSubmission(_ value: Any?, stage: String) {
    guard (value as? [String: Any])?["submitted"] as? Bool == true else {
      pause("天成表单未就绪或检测到人工输入，自动登录已暂停；保存配置可重试")
      return
    }
    self.stage = stage
    submittedAt = Date()
    schedule()
  }

  private func pause(_ message: String) {
    call("pause()") { [weak self] _ in
      self?.onState(.authenticationRequired(message))
      self?.schedule(after: 10)
    }
  }
}
