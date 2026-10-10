import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const source = fs.readFileSync(new URL('../Sources/SMSMonitorApp/MonitorController.swift', import.meta.url), 'utf8');
const section = (start, end) => source.slice(source.indexOf(start), source.indexOf(end, source.indexOf(start)));
// Execute the production recovery and both scheduler entry guards; stop before network I/O.
const methods = [
  section('  private var needsAuthenticatedPageRecovery', '  private func persistCurrentToken()'),
  section('  private func refreshFinancialMetricsNow()', '    isRefreshingFinancial = true') + '    requests += 1\n  }',
  section('  func scanNow()', '    guard !isScanning,') + '    smsScans += 1\n  }',
].join('\n').replaceAll('private var ', 'var ').replaceAll('private func ', 'func ');

const harness = `
import Foundation
import OSLog
enum World { case page }
enum State { case starting(String), authenticationRequired(String), disabled }
enum AuthenticatedPageSessionScript { static let body = "fixture" }
final class Page {
  var url: URL? = URL(string: "https://fixture.invalid/rp/game-report")
  var isLoading = false
  var probes = 0
  var callback: ((Result<Any, Error>) -> Void)?
  func callAsyncJavaScript(_ script: String, arguments: [String: Any], in frame: NSObject?, in world: World,
    completionHandler: @escaping (Result<Any, Error>) -> Void) { probes += 1; callback = completionHandler }
}
struct Profile { let username = "fixture" }
final class Store {
  var updates = 0
  func profile(for id: String) -> Profile? { Profile() }
  func updateToken(_ token: String, for id: String) { updates += 1 }
}
final class Controller {
  static let authenticationLogger = Logger(subsystem: "sms-monitor-test", category: "Authentication")
  static let financialRefreshInterval: TimeInterval = 20
  let configuration = (id: "fixture", name: "fixture")
  let webView = Page(), credentialStore = Store()
  var isStarted = true, monitoringEnabled = true, smsMonitoringEnabled = false, financialMonitoringEnabled = true
  var browserOnlyPage = false, isMemoryCompacted = false, platformIdentified = true
  var manualAuthenticationRequired = false, credentialLoginPending = true, autoLoginInProgress = false
  var isScanning = false, isRefreshingFinancial = false, needsImmediateScan = false
  var smsPermissionBlocked = false, financePermissionBlocked = false, apiAuthenticationValidationAttempted = true
  var authenticatedPageRecoveryID: UUID?, authenticationEpoch = UUID()
  var autoLoginStage = "totp", loginCompletionDeadline: Date? = Date.distantPast
  var autoLoginCooldownUntil: Date? = Date.distantFuture
  var captchaAutoLoginAttempts = 3, totpAutoLoginAttempts = 2
  var autoLoginOutcomeWorkItem: DispatchWorkItem?
  var latestEmittedState: State? = .authenticationRequired("login completion timed out")
  var lastMetrics: String?, lastMetricsScannedAt: Date?, latestDailyFinancialMetrics: String?
  var mockScenario: String?, tianchengLogin: NSObject?
  var requests = 0, smsScans = 0, scheduled = 0, resumed = 0, loginAttempts = 0
  func requiresAuthentication(_ url: URL) -> Bool { ["/login", "/ga-auth", "/unlock-ip"].contains(url.path) }
  func requiresInteractiveAuthentication(_ url: URL) -> Bool { requiresAuthentication(url) }
  func isMonitorOrigin(_ url: URL) -> Bool { url.host == "fixture.invalid" }
  func resetAccountIdentityRecovery() {}
  func emit(_ state: State, nextScanAt: Date?) { latestEmittedState = state }
  func scheduleFinancialRefresh(after: TimeInterval) { scheduled += 1 }
  func ensureFinancialRefreshScheduled() { resumed += 1 }
  func scheduleNextScan(after: TimeInterval) {}
  func handleAuthenticationRequired(_ message: String) { loginAttempts += 1 }
  func emitMockState() {}
  func refreshTianchengFinancialMetrics() {}
  func identifyPlatform(_ completion: () -> Void) { platformIdentified = true; completion() }
${methods}
}
func check(_ value: Bool, _ text: String) {
  if !value { fatalError(text) }
  print("PASS: " + text)
}
func reply(_ c: Controller, kind: String = "authenticated") {
  c.webView.callback?(.success(["kind": kind, "token": "fixture-token"]))
  RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}
let c = Controller()
c.refreshFinancialMetricsNow()
check(c.webView.probes == 1 && c.requests == 0, "data-only finance tick probes pending login before querying")
c.refreshFinancialMetricsNow()
check(c.webView.probes == 1, "concurrent ticks do not duplicate session probes")
reply(c)
check(!c.credentialLoginPending && !c.manualAuthenticationRequired && c.loginCompletionDeadline == nil && c.autoLoginCooldownUntil == nil,
  "late authenticated business page clears expired completion deadline and pending flags")
check(c.autoLoginStage.isEmpty && c.resumed == 1 && c.loginAttempts == 0, "resume finance without submitting credentials")
c.refreshFinancialMetricsNow()
check(c.requests == 1 && c.smsScans == 0, "data-only mode reaches finance and keeps SMS disabled")
let selection = Controller()
selection.credentialLoginPending = false
selection.scanNow()
check(selection.webView.probes == 1 && selection.smsScans == 0, "data-only selection repairs stale auth display even without pending flag")
reply(selection)
check(selection.resumed > 0 && selection.credentialStore.updates == 1, "matched page identity resumes its own configured account")
for kind in ["accountMismatch", "accountConflict", "signedOut", "missingToken"] {
  let bad = Controller()
  bad.manualAuthenticationRequired = true
  bad.refreshFinancialMetricsNow()
  reply(bad, kind: kind)
  check(bad.manualAuthenticationRequired && bad.credentialLoginPending && bad.requests == 0 && bad.resumed == 0,
    "rejected " + kind + " cannot clear authentication or query")
}
for path in ["", "/", "/login", "/ga-auth", "/unlock-ip", "/.sms-monitor-memory-shell"] {
  let blocked = Controller()
  blocked.webView.url = URL(string: "https://fixture.invalid" + path)
  blocked.refreshFinancialMetricsNow()
  check(blocked.webView.probes == 0 && blocked.requests == 0, "no recovery on " + path)
}
for condition in 0..<6 {
  let blocked = Controller()
  if condition == 0 { blocked.webView.isLoading = true }
  if condition == 1 { blocked.autoLoginInProgress = true }
  if condition == 2 { blocked.isStarted = false }
  if condition == 3 { blocked.monitoringEnabled = false }
  if condition == 4 { blocked.isMemoryCompacted = true }
  if condition == 5 { blocked.webView.url = URL(string: "https://other.invalid/report") }
  blocked.reconcileAuthenticatedBusinessPageIfNeeded()
  check(blocked.webView.probes == 0, "loading, active login, stopped, compacted or foreign pages stay blocked " + String(condition))
}
for condition in 0..<4 {
  let stale = Controller()
  stale.refreshFinancialMetricsNow()
  if condition == 0 { stale.authenticationEpoch = UUID() }
  if condition == 1 { stale.webView.url = URL(string: "https://fixture.invalid/ga-auth") }
  if condition == 2 { stale.isStarted = false }
  if condition == 3 { stale.webView.isLoading = true }
  reply(stale)
  check(stale.credentialLoginPending && stale.resumed == 0 && stale.credentialStore.updates == 0,
    "stale callback cannot restore changed session/page " + String(condition))
}
`;
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sms-data-only-session-'));
try {
  const file = path.join(dir, 'Check.swift');
  fs.writeFileSync(file, harness);
  execFileSync('swift', [file], { stdio: 'inherit', timeout: 60000 });
} finally {
  fs.rmSync(dir, { recursive: true, force: true });
}
