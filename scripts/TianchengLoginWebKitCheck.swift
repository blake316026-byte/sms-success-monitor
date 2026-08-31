import AppKit
import WebKit

@MainActor
final class TianchengCheck: NSObject, WKNavigationDelegate {
  private var page: WKWebView!
  private let source: String
  init(source: String) { self.source = source }

  func start() {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    page = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
    page.navigationDelegate = self
    page.loadHTMLString(#"""
      <html><body>
      <script>const apiPath = '/tac/api/theme_domain/theme';</script>
      <div class="admin-login"><div class="admin-login-table">
        <form><input id="operatorName"><input id="password" type="password" placeholder="Google verification code">
        <button type="submit">Log in</button></form>
      </div><div class="admin-login-footer"><button role="switch" aria-checked="false">Verify</button></div></div>
      <script>
        window.requests = 0;
        window.passwordSubmits = 0;
        window.totpSubmits = 0;
        window.model = {};
        window.fetch = () => { requests++; throw Error('unexpected API request'); };
        document.addEventListener('input', e => { model[e.target.id] = e.target.value; });
        document.querySelector('[role=switch]').onclick = e => {
          e.currentTarget.setAttribute('aria-checked', 'true');
          document.querySelector('#password').placeholder = 'Password';
        };
        document.querySelector('form').onsubmit = e => {
          e.preventDefault();
          if(document.querySelector('[role=switch]').getAttribute('aria-checked') !== 'true') throw Error('password sent as OTP');
          if(model.operatorName !== 'fixture-user' || model.password !== 'fixture-password') throw Error('React input model not updated');
          passwordSubmits++;
          document.querySelector('.admin-login-table').innerHTML = '<form><input id="otp"><button type="submit">Submit</button></form>';
          document.querySelector('.admin-login-footer').remove();
          document.querySelector('form').onsubmit = e => { e.preventDefault(); totpSubmits++; };
        };
      </script></body></html>
      """#, baseURL: URL(string: "https://tiancheng-fixture.invalid/")!)
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.finish(false, "timeout") }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    let code = source + #"""
      const a = globalThis.smsTianchengLogin;
      const check = (ok, message) => { if(!ok) throw Error(message); };
      check(a.detect(), 'provider not detected');
      check(a.snapshot().kind === 'password', 'root login not detected');
      const p = await a.submitPassword({username:'fixture-user',password:'fixture-password'});
      check(p.submitted && passwordSubmits === 1, 'password mode switch or submit failed');
      check(a.snapshot().kind === 'totp' && location.pathname === '/', 'same URL second factor not detected');
      const duplicatePassword = await a.submitPassword({username:'fixture-user',password:'fixture-password'});
      check(!duplicatePassword.submitted && passwordSubmits === 1, 'duplicate password submit');
      document.querySelector('.admin-login-table').insertAdjacentHTML('afterbegin','<div class="login-qrcode">Bind</div>');
      check(a.snapshot().kind === 'manual', 'binding was not blocked');
      check(!(await a.submitTotp({code:'123456'})).submitted, 'automatically bound a key');
      document.querySelector('.login-qrcode').remove();
      check(!(await a.submitTotp({code:'invalid'})).submitted, 'invalid OTP submitted');
      const t = await a.submitTotp({code:'123456'});
      check(t.submitted && model.otp === '123456' && totpSubmits === 1, 'OTP submit failed');
      check(!(await a.submitTotp({code:'654321'})).submitted && totpSubmits === 1, 'OTP automatically retried');
      a.pause();
      check(a.snapshot().kind === 'manual' && sessionStorage.getItem('sms-tiancheng-login-paused') === '1', 'pause not persistent');
      a.reset();
      document.querySelector('.admin-login').remove();
      sessionStorage.setItem('temporaryToken', 'fixture-temporary-token');
      check(a.snapshot().kind === 'waiting', 'temporary token was treated as authenticated');
      history.replaceState({}, '', '/index');
      sessionStorage.setItem('tabIsLogin', '1');
      sessionStorage.setItem('TOKEN', 'fixture-final-token');
      check(a.snapshot().kind === 'authenticated', 'authenticated session not detected');
      check(requests === 0, 'API requests during DOM login adaptation');
      document.querySelector('script').remove();
      check(!a.detect() && a.snapshot().kind === 'unknown', 'unrelated page classified as Tiancheng');
      return true;
      """#
    page.callAsyncJavaScript(code, arguments: [:], in: nil, in: .page) { result in
      switch result {
      case .success(let value): self.finish(value as? Bool == true, "native WebKit Tiancheng password switch, same-URL OTP, duplicate prevention, binding guard and zero queries")
      case .failure(let error): self.finish(false, error.localizedDescription)
      }
    }
  }

  private func finish(_ success: Bool, _ message: String) {
    print("\(success ? "PASS" : "FAIL"): \(message)")
    exit(success ? 0 : 1)
  }
}

@main
struct TianchengLoginWebKitCheck {
  @MainActor static func main() throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
    let check = TianchengCheck(source: source)
    check.start()
    app.run()
  }
}
