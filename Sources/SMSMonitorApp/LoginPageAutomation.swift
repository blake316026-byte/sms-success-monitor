import Foundation
import WebKit

struct LoginPageSnapshot {
  let kind: String
  let captchaDataURL: String
  let token: String
  let clockOffsetMilliseconds: Double
}

struct LoginPageSubmission {
  let submitted: Bool
  let manual: Bool
  let message: String
}

struct LoginPageIdentity {
  let username: String
  let manual: Bool
}

final class LoginPageAutomation {
  private let source: String
  private var pendingCalls: [UUID: DispatchWorkItem] = [:]

  init() {
    let url = Bundle.main.resourceURL?
      .appendingPathComponent("auto-login")
      .appendingPathComponent("login-page.js")
    source = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
  }

  func identity(
    in webView: WKWebView,
    completion: @escaping (Result<LoginPageIdentity, Error>) -> Void
  ) {
    call(
      in: webView,
      body: "return globalThis.smsLoginAutomation.loginIdentity();",
      arguments: [:]
    ) { result in
      completion(result.flatMap { value in
        guard let payload = value as? [String: Any] else {
          return .failure(LocalAutomationRuntimeError.invalidResult)
        }
        return .success(
          LoginPageIdentity(
            username: payload["username"] as? String ?? "",
            manual: payload["manual"] as? Bool ?? false
          )
        )
      })
    }
  }

  func snapshot(
    in webView: WKWebView,
    completion: @escaping (Result<LoginPageSnapshot, Error>) -> Void
  ) {
    call(
      in: webView,
      body: "return await globalThis.smsLoginAutomation.snapshot();",
      arguments: [:]
    ) { result in
      completion(result.flatMap { value in
        guard let payload = value as? [String: Any], let kind = payload["kind"] as? String else {
          return .failure(LocalAutomationRuntimeError.invalidResult)
        }
        return .success(
          LoginPageSnapshot(
            kind: kind,
            captchaDataURL: payload["captchaDataUrl"] as? String ?? "",
            token: payload["token"] as? String ?? "",
            clockOffsetMilliseconds: (payload["clockOffsetMs"] as? NSNumber)?.doubleValue ?? 0
          )
        )
      })
    }
  }

  func submitLogin(
    in webView: WKWebView,
    profile: LocalLoginProfile,
    captcha: String,
    completion: @escaping (Result<LoginPageSubmission, Error>) -> Void
  ) {
    call(
      in: webView,
      body: """
        return await globalThis.smsLoginAutomation.submitLogin({
          username,
          password,
          captcha
        });
        """,
      arguments: [
        "username": profile.username,
        "password": profile.password,
        "captcha": captcha,
      ]
    ) { result in
      completion(result.flatMap(Self.loginSubmissionResult))
    }
  }

  func submitTOTP(
    in webView: WKWebView,
    code: String,
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    call(
      in: webView,
      body: "return await globalThis.smsLoginAutomation.submitTotp({ code });",
      arguments: ["code": code]
    ) { result in
      completion(result.flatMap(Self.submittedResult))
    }
  }

  func extractToken(in webView: WKWebView, expectedUsername: String = "", completion: @escaping (String) -> Void) {
    call(
      in: webView,
      body: "return globalThis.smsLoginAutomation.extractToken(expectedUsername);",
      arguments: ["expectedUsername": expectedUsername]
    ) { result in
      completion((try? result.get()) as? String ?? "")
    }
  }

  func refreshCaptcha(in webView: WKWebView) {
    call(
      in: webView,
      body: "return globalThis.smsLoginAutomation.refreshCaptcha();",
      arguments: [:]
    ) { _ in }
  }

  private func call(
    in webView: WKWebView,
    body: String,
    arguments: [String: Any],
    completion: @escaping (Result<Any, Error>) -> Void
  ) {
    guard !source.isEmpty else {
      completion(.failure(LocalAutomationRuntimeError.resourceMissing("login-page.js")))
      return
    }
    let callID = UUID()
    let timeout = DispatchWorkItem { [weak self] in
      guard self?.pendingCalls.removeValue(forKey: callID) != nil else { return }
      completion(.failure(LocalAutomationRuntimeError.pageOperationTimedOut))
    }
    pendingCalls[callID] = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    webView.callAsyncJavaScript(
      "\(source)\n\(body)",
      arguments: arguments,
      in: nil,
      in: .page
    ) { [weak self] result in
      DispatchQueue.main.async {
        guard let timeout = self?.pendingCalls.removeValue(forKey: callID) else { return }
        timeout.cancel()
        completion(result)
      }
    }
  }

  private static func submittedResult(_ value: Any) -> Result<Bool, Error> {
    guard let payload = value as? [String: Any] else {
      return .failure(LocalAutomationRuntimeError.invalidResult)
    }
    return .success(payload["submitted"] as? Bool ?? false)
  }

  private static func loginSubmissionResult(_ value: Any) -> Result<LoginPageSubmission, Error> {
    guard let payload = value as? [String: Any] else {
      return .failure(LocalAutomationRuntimeError.invalidResult)
    }
    return .success(
      LoginPageSubmission(
        submitted: payload["submitted"] as? Bool ?? false,
        manual: payload["manual"] as? Bool ?? false,
        message: payload["message"] as? String ?? ""
      )
    )
  }
}
