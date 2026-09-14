import assert from 'node:assert/strict';
import fs from 'node:fs';

const monitor = fs.readFileSync(
  new URL('../Sources/SMSMonitorApp/MonitorController.swift', import.meta.url),
  'utf8'
);
const workspace = fs.readFileSync(
  new URL('../Sources/SMSMonitorApp/PlatformWorkspaceController.swift', import.meta.url),
  'utf8'
);

const section = (source, from, to) => {
  const start = source.indexOf(from);
  const end = source.indexOf(to, start + from.length);
  assert(start >= 0 && end > start, `missing source section ${from}`);
  return source.slice(start, end);
};

const compaction = section(
  monitor,
  'private func compactInactivePageIfNeeded(',
  'func credentialsDidChange()'
);
const activation = section(
  monitor,
  'func setPageActive(_ active: Bool)',
  'func scanNow()'
);
assert(
  activation.indexOf('isPageActive = active') < activation.indexOf('restoreCompactedPageIfNeeded()'),
  'the page must become active before restoration can trigger WebKit callbacks'
);
assert(
  activation.indexOf('inactiveSince = nil') < activation.indexOf('restoreCompactedPageIfNeeded()'),
  'restoration must clear the inactive deadline before loading the full page'
);
assert.match(compaction, /lastSuccessfulScanAt[\s\S]*!isPageActive/,
  'only inactive pages with a fresh successful scan may compact');
assert.match(compaction, /browserOnlyPage \|\| !monitoringEnabled[\s\S]*\|\| manualAuthenticationRequired/,
  'hidden pages with no runnable background task may compact without a scan');
assert.match(compaction, /case \.authenticationRequired = latestEmittedState[\s\S]*authenticationPaused/,
  'hidden pages whose automatic authentication is paused may compact');
assert.match(monitor, /case \.authenticationRequired = state, !isPageActive[\s\S]*scheduleInactivePageCompactionIfNeeded/,
  'authentication pauses must restart the hidden-page compaction timer');
assert.match(compaction, /!requiresInteractiveAuthentication\(currentURL\) \|\| sessionOnlyPage/,
  'a hidden page waiting for manual authentication may release its renderer');
assert.match(monitor, /finishFinancialRefresh\(result\)[\s\S]*compactInactivePageIfNeeded\(now: Date\(\)\)/,
  'financial refresh completion must retry compaction when it previously occupied the page');
assert.match(monitor, /if !isPageActive \{[\s\S]*scheduleInactivePageCompactionIfNeeded\(\)[\s\S]*mockScenario/,
  'hidden monitors must schedule compaction even before their staggered startup');
assert.match(compaction, /window\.sessionStorage[\s\S]*JSON\.stringify\(entries\)/,
  'session storage must be captured before replacing a WebView');
assert.match(compaction, /suspendedTianchengLogin\?\.stop\(\)[\s\S]*suspendedTianchengLogin\?\.start\(\)/,
  'Tiancheng polling must be serialized with session capture and resumed on failure');
assert.match(compaction, /let replacement = WKWebView[\s\S]*webView = replacement/,
  'memory compaction must replace the heavy WebView process');
assert.match(compaction, /components\.path = "\/\.sms-monitor-memory-shell"[\s\S]*components\.query = nil[\s\S]*components\.fragment = nil/,
  'the lightweight page must use a distinct same-origin URL');
assert.match(compaction, /let shellBaseURL = Self\.compactedPageBaseURL\(for: currentURL\)[\s\S]*loadHTMLString\([\s\S]*baseURL: shellBaseURL/,
  'the lightweight page must not impersonate the exact business page URL');
assert.match(compaction, /restoreCompactedPageIfNeeded[\s\S]*webView\.load\(URLRequest\(url: restoreURL\)\)/,
  'selecting a compacted platform must restore its full page');
assert.match(compaction, /tianchengLogin\?\.attach\(to: webView\)[\s\S]*tianchengLogin\?\.start\(\)/,
  'restoring a compacted Tiancheng page must reconnect its login controller');
assert.match(compaction, /Released inactive WebKit page memory[\s\S]*Restoring visible platform page/,
  'memory compaction and restoration must emit auditable diagnostics');
assert.match(monitor, /func webView\(_ webView: WKWebView, didFinish[\s\S]*guard !isMemoryCompacted else \{ return \}/,
  'the lightweight shell must not restart login or page navigation workflows');
assert.match(monitor, /func start\(after delay:[\s\S]*if isPageActive \{[\s\S]*restoreCompactedPageIfNeeded\(\)/,
  'enabling monitoring on a visible compacted page must restore the full page');
assert.match(monitor, /private func handleAuthenticationRequired[\s\S]*if isMemoryCompacted \{[\s\S]*restoreCompactedPageIfNeeded\(\)/,
  'authentication recovery must restore the full page before running login automation');

const replacement = section(
  workspace,
  'func replaceWebView(',
  'func refreshMonitorCount()'
);
assert.match(replacement, /page\.replaceWebView\(replacement\)/,
  'the visible workspace must release its reference to the old WebView');
assert.match(workspace, /private\(set\) var webView: WKWebView/,
  'platform pages must support safe WebView replacement');

console.log('PASS: inactive pages release heavy WebKit processes and restore on selection');
