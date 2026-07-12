import Foundation
import WebKit

struct LoginPageSnapshot {
  let kind: String
  let captchaDataURL: String
  let token: String
}

final class LoginPageAutomation {
  private let source: String

  init() {
    let url = Bundle.main.resourceURL?
      .appendingPathComponent("auto-login")
      .appendingPathComponent("login-page.js")
    source = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
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
            token: payload["token"] as? String ?? ""
          )
        )
      })
    }
  }

  func submitLogin(
    in webView: WKWebView,
    profile: LocalLoginProfile,
    captcha: String,
    completion: @escaping (Result<Bool, Error>) -> Void
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
      completion(result.flatMap(Self.submittedResult))
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

  func extractToken(in webView: WKWebView, completion: @escaping (String) -> Void) {
    call(
      in: webView,
      body: "return globalThis.smsLoginAutomation.extractToken();",
      arguments: [:]
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
    webView.callAsyncJavaScript(
      "\(source)\n\(body)",
      arguments: arguments,
      in: nil,
      in: .page
    ) { result in
      DispatchQueue.main.async { completion(result) }
    }
  }

  private static func submittedResult(_ value: Any) -> Result<Bool, Error> {
    guard let payload = value as? [String: Any] else {
      return .failure(LocalAutomationRuntimeError.invalidResult)
    }
    return .success(payload["submitted"] as? Bool ?? false)
  }
}
