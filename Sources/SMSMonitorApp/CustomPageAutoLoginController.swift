import Foundation
import SMSMonitorCore
import WebKit

final class CustomPageAutoLoginController {
  private static let cooldown: TimeInterval = 300

  private let credentialID: String
  private weak var webView: WKWebView?
  private let credentialStore: LocalCredentialStore
  private let automationRuntime: LocalAutomationRuntime
  private let loginAutomation: LoginPageAutomation

  private var captchaAttempts = 0
  private var totpAttempts = 0
  private var inProgress = false
  private var stage = ""
  private var cooldownUntil: Date?
  private var outcomeWorkItem: DispatchWorkItem?
  private var retryWorkItem: DispatchWorkItem?

  init(
    credentialID: String,
    webView: WKWebView,
    credentialStore: LocalCredentialStore,
    automationRuntime: LocalAutomationRuntime,
    loginAutomation: LoginPageAutomation
  ) {
    self.credentialID = credentialID
    self.webView = webView
    self.credentialStore = credentialStore
    self.automationRuntime = automationRuntime
    self.loginAutomation = loginAutomation
  }

  func navigationDidFinish() {
    guard let url = webView?.url else { return }
    if requiresAuthentication(url) {
      attemptIfConfigured(url: url)
    } else {
      reset()
      persistCurrentToken()
    }
  }

  func credentialsDidChange() {
    reset()
    guard let url = webView?.url, requiresAuthentication(url) else {
      persistCurrentToken()
      return
    }
    attemptIfConfigured(url: url)
  }

  func stop() {
    outcomeWorkItem?.cancel()
    retryWorkItem?.cancel()
    inProgress = false
  }

  private func attemptIfConfigured(url: URL) {
    guard let profile = credentialStore.profile(for: credentialID), profile.canAutoLogin else {
      return
    }
    attempt(profile: profile, url: url)
  }

  private func attempt(profile: LocalLoginProfile, url: URL) {
    guard !inProgress, let webView else { return }
    guard url.path != "/unlock-ip" else { return }
    if let cooldownUntil, cooldownUntil > Date() { return }
    let isTOTP = url.path == "/ga-auth"
    let attempts = isTOTP ? totpAttempts : captchaAttempts
    let maximumAttempts = isTOTP
      ? AutoLoginAttemptPolicy.maximumTOTPAttempts
      : AutoLoginAttemptPolicy.maximumCaptchaAttempts
    if attempts >= maximumAttempts {
      cooldownUntil = Date().addingTimeInterval(Self.cooldown)
      return
    }

    inProgress = true
    loginAutomation.snapshot(in: webView) { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure:
        self.retry()
      case .success(let snapshot):
        if !snapshot.token.isEmpty {
          self.credentialStore.updateToken(snapshot.token, for: self.credentialID)
        }
        switch snapshot.kind {
        case "login":
          self.solveCaptcha(profile: profile, dataURL: snapshot.captchaDataURL)
        case "totp":
          self.submitTOTP(
            profile: profile,
            clockOffsetMilliseconds: snapshot.clockOffsetMilliseconds
          )
        case "authenticated":
          self.complete(token: snapshot.token)
        case "manual", "unlock-ip":
          self.inProgress = false
        default:
          self.retry()
        }
      }
    }
  }

  private func solveCaptcha(profile: LocalLoginProfile, dataURL: String) {
    guard !dataURL.isEmpty, let webView else {
      retry()
      return
    }
    automationRuntime.recognize(dataURL: dataURL) { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure:
        self.retry()
      case .success(let captcha):
        guard captcha.range(of: #"^[0-9A-Za-z]{4}$"#, options: .regularExpression) != nil else {
          self.loginAutomation.refreshCaptcha(in: webView)
          self.retry()
          return
        }
        self.loginAutomation.submitLogin(
          in: webView,
          profile: profile,
          captcha: captcha
        ) { [weak self] result in
          guard let self else { return }
          switch result {
          case .failure:
            self.retry()
          case .success(let submission):
            guard !submission.manual else {
              self.inProgress = false
              return
            }
            guard submission.submitted else {
              self.retry()
              return
            }
            self.stage = "login"
            self.scheduleOutcomeCheck()
          }
        }
      }
    }
  }

  private func submitTOTP(
    profile: LocalLoginProfile,
    clockOffsetMilliseconds: Double
  ) {
    let secret = profile.totpSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !secret.isEmpty else {
      inProgress = false
      return
    }
    let serverOffset = clockOffsetMilliseconds.isFinite
      && abs(clockOffsetMilliseconds) <= 43_200_000
      ? clockOffsetMilliseconds / 1_000
      : 0
    let retryOffsets = [0, -30, 30, -60, 60]
    let offset = serverOffset + Double(retryOffsets[min(totpAttempts, retryOffsets.count - 1)])
    let adjustedNow = Date().addingTimeInterval(offset)
    let cyclePosition = adjustedNow.timeIntervalSince1970.truncatingRemainder(dividingBy: 30)
    let delay = cyclePosition > 24 ? 6.5 : 0

    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self, self.inProgress, let webView = self.webView else { return }
      self.automationRuntime.generateTOTP(
        secret: secret,
        timestamp: Date().addingTimeInterval(offset)
      ) { [weak self] result in
        guard let self else { return }
        switch result {
        case .failure:
          self.retry()
        case .success(let code):
          self.loginAutomation.submitTOTP(in: webView, code: code) { [weak self] result in
            guard let self else { return }
            guard (try? result.get()) == true else {
              self.retry()
              return
            }
            self.stage = "totp"
            self.scheduleOutcomeCheck()
          }
        }
      }
    }
  }

  private func scheduleOutcomeCheck() {
    outcomeWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self, let webView = self.webView, let url = webView.url else { return }
      self.inProgress = false
      if self.requiresAuthentication(url) {
        if url.path == "/ga-auth", self.stage != "totp",
          let profile = self.credentialStore.profile(for: self.credentialID)
        {
          self.stage = ""
          self.attempt(profile: profile, url: url)
        } else {
          if url.path == "/login" {
            self.loginAutomation.refreshCaptcha(in: webView)
          }
          self.retry()
        }
      } else {
        self.complete(token: "")
      }
    }
    outcomeWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: item)
  }

  private func retry() {
    inProgress = false
    stage = ""
    let isTOTP = webView?.url?.path == "/ga-auth"
    if isTOTP {
      totpAttempts += 1
    } else {
      captchaAttempts += 1
    }
    let attempts = isTOTP ? totpAttempts : captchaAttempts
    let maximumAttempts = isTOTP
      ? AutoLoginAttemptPolicy.maximumTOTPAttempts
      : AutoLoginAttemptPolicy.maximumCaptchaAttempts
    guard attempts < maximumAttempts else {
      cooldownUntil = Date().addingTimeInterval(Self.cooldown)
      return
    }
    retryWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self, let url = self.webView?.url else { return }
      self.attemptIfConfigured(url: url)
    }
    retryWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
  }

  private func complete(token: String) {
    reset()
    if !token.isEmpty {
      credentialStore.updateToken(token, for: credentialID)
    } else {
      persistCurrentToken()
    }
  }

  private func persistCurrentToken() {
    guard let webView else { return }
    loginAutomation.extractToken(in: webView) { [weak self] token in
      guard let self, !token.isEmpty else { return }
      self.credentialStore.updateToken(token, for: self.credentialID)
    }
  }

  private func reset() {
    captchaAttempts = 0
    totpAttempts = 0
    inProgress = false
    stage = ""
    cooldownUntil = nil
    outcomeWorkItem?.cancel()
    retryWorkItem?.cancel()
  }

  private func requiresAuthentication(_ url: URL) -> Bool {
    ["/login", "/ga-auth", "/unlock-ip"].contains(url.path)
  }
}
