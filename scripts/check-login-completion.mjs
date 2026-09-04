import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const source = fs.readFileSync(new URL('../Sources/SMSMonitorApp/MonitorController.swift', import.meta.url), 'utf8');
const section = (start, end) => source.slice(source.indexOf(start), source.indexOf(end, source.indexOf(start)));
const didFinish = section('  func webView(_ webView: WKWebView, didFinish', '  func webView(\n');
assert.ok(didFinish.length > 0);
assert.doesNotMatch(didFinish, /autoLoginInProgress = false|autoLoginStage = ""|autoLoginOutcomeWorkItem\?\.cancel/);
const scan = section('  func scanNow()', '  func updateSampleLimit');
assert.match(scan, /if credentialLoginPending \{\s*confirmAutoLoginCompletion\(\)/);
const methods = [
  section('  private func scheduleAutoLoginOutcomeCheck(', '  private func retryAutoLogin('),
  section('  private func completeAutoLogin(', '  private func persistCurrentToken('),
  didFinish,
].join('\n').replaceAll('private func ', 'func ').replaceAll('WKWebView', 'Page').replaceAll('WKNavigation', 'NSObject');

// Compile the production transition methods against deterministic collaborators.
// No real credentials, HTTP calls, browser stores or platform accounts are used.
const harness = `
import Foundation
final class Page {
  var url: URL? = URL(string: "https://fixture.invalid/")
  var isLoading = false
  var loads = 0
  func load(_ request: URLRequest) { loads += 1; url = request.url }
}
struct Profile { let username = "fixture" }
final class Store {
  func profile(for id: String) -> Profile? { Profile() }
  func updateToken(_ token: String, for id: String) {}
}
final class Automation {
  var token = "fixture-token"
  var deferCallback = false
  var pending: ((String) -> Void)?
  func extractToken(in page: Page, expectedUsername: String, completion: @escaping (String) -> Void) {
    if deferCallback { pending = completion } else { completion(token) }
  }
  func refreshCaptcha(in page: Page) {}
}
enum State { case authenticationRequired(String), starting(String) }
final class Controller {
  static let autoLoginCooldown: TimeInterval = 300
  let configuration = (id: "fixture", targetURL: URL(string: "https://fixture.invalid/dashboard")!)
  let credentialStore = Store(), loginAutomation = Automation(), webView = Page()
  var autoLoginInProgress = true, credentialLoginPending = true, manualAuthenticationRequired = false
  var autoLoginStage = "totp", captchaAutoLoginAttempts = 2, totpAutoLoginAttempts = 1
  var autoLoginCooldownUntil: Date?, loginCompletionDeadline: Date?, nextScanAt: Date?
  var autoLoginOutcomeWorkItem: DispatchWorkItem?, scanTimeoutWorkItem: DispatchWorkItem?
  var authenticationEpoch = UUID(), activeScanID: UUID?
  var isScanning = false, isRefreshingFinancial = false, needsImmediateScan = false
  var monitoringEnabled = true, browserOnlyPage = false, platformIdentified = true
  var tianchengLogin: NSObject? = nil
  var scans = 0, logins = 0, financialStarts = 0
  func requiresAuthentication(_ url: URL) -> Bool { ["/login", "/ga-auth", "/unlock-ip"].contains(url.path) }
  func requiresInteractiveAuthentication(_ url: URL) -> Bool { requiresAuthentication(url) }
  func isMonitorOrigin(_ url: URL) -> Bool { url.host == "fixture.invalid" }
  func retryAutoLogin(_ message: String) { logins += 1 }
  func attemptAutoLogin(profile: Profile, url: URL) { logins += 1 }
  func handleAuthenticationRequired(_ message: String) { logins += 1 }
  func resetAccountIdentityRecovery() {}
  func persistCurrentToken() {}
  func ensureFinancialRefreshScheduled() { financialStarts += 1 }
  func emit(_ state: State, nextScanAt: Date?) {}
  func scanNow() { scans += 1 }
  func resumeAuthenticationOnlyIfNeeded() {}
  func emitBrowserOnlyState() {}
  func identifyPlatform(_ completion: () -> Void) { completion() }
  func scheduleConnectionKickoff() { scans += 1 }
${methods}
}
func check(_ value: Bool, _ message: String) {
  guard value else { fatalError(message) }
  print("PASS: " + message)
}
let c = Controller()
let epoch = c.authenticationEpoch
c.webView(c.webView, didFinish: nil)
check(c.credentialLoginPending && c.autoLoginInProgress && c.autoLoginStage == "totp", "root navigation preserves pending recovery and TOTP stage")
check(c.scans == 0 && c.financialStarts == 0, "root navigation starts no protected query")
c.autoLoginOutcomeWorkItem?.perform()
check(c.credentialLoginPending && c.logins == 0, "root loading never sends the account back to login")
c.webView.url = URL(string: "https://fixture.invalid/ga-auth")
c.autoLoginStage = "login"
c.autoLoginOutcomeWorkItem?.perform()
check(c.logins == 1 && c.credentialLoginPending, "second factor remains part of the original recovery")
c.webView.url = URL(string: "https://fixture.invalid/dashboard")
c.loginAutomation.token = ""
c.confirmAutoLoginCompletion()
check(c.credentialLoginPending && c.financialStarts == 0, "business route without matching account token is not authenticated")
c.loginAutomation.token = "fixture-token"
c.confirmAutoLoginCompletion()
check(!c.credentialLoginPending && !c.autoLoginInProgress && c.autoLoginStage.isEmpty, "confirmed session atomically clears recovery before scans")
check(c.authenticationEpoch != epoch && c.financialStarts == 1 && c.webView.loads == 0, "confirmation invalidates old callbacks without navigating to login")
let stale = Controller()
stale.webView.url = URL(string: "https://fixture.invalid/dashboard")
stale.loginAutomation.deferCallback = true
stale.confirmAutoLoginCompletion()
stale.authenticationEpoch = UUID()
stale.loginAutomation.pending?("old-token")
check(stale.credentialLoginPending && stale.financialStarts == 0, "stale completion cannot authenticate a newer session")
let timeout = Controller()
timeout.loginCompletionDeadline = Date.distantPast
timeout.confirmAutoLoginCompletion()
check(timeout.autoLoginCooldownUntil != nil && timeout.logins == 0 && timeout.webView.loads == 0, "stalled bootstrap pauses without repeating password login")
`;
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sms-login-completion-'));
try {
  const file = path.join(dir, 'Check.swift');
  fs.writeFileSync(file, harness);
  execFileSync('swift', [file], { stdio: 'inherit', timeout: 60_000 });
} finally {
  fs.rmSync(dir, { recursive: true, force: true });
}
