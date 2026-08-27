import assert from 'node:assert/strict';
import fs from 'node:fs';

const source = fs.readFileSync(new URL('../Sources/SMSMonitorApp/MonitorController.swift', import.meta.url), 'utf8');
const section = (from, to) => {
  const start = source.indexOf(from);
  const end = source.indexOf(to, start + from.length);
  assert(start >= 0 && end > start, `missing source section ${from}`);
  return source.slice(start, end);
};
const ensure = section('private func ensureFinancialRefreshScheduled()', 'private func refreshFinancialMetricsNow()');
assert.match(ensure, /guard isStarted, !financePermissionBlocked, !isRefreshingFinancial/);
assert.match(ensure, /financialRefreshWorkItem == nil \|\| financialRefreshWorkItem\?\.isCancelled == true/);
assert.match(ensure, /scheduleFinancialRefresh\(after: 1\)/);
assert.match(section('private func completeAutoLogin(token:', 'private func persistCurrentToken()'), /ensureFinancialRefreshScheduled\(\)/);
assert.match(section('didFinish navigation:', 'didFailProvisionalNavigation'), /ensureFinancialRefreshScheduled\(\)/);
assert.match(section('case "ok":', 'case "auth":'), /ensureFinancialRefreshScheduled\(\)/);
assert.match(section('if event == "ended"', '} else if event == "authenticated"'), /financialRefreshWorkItem\?\.cancel\(\)\s+financialRefreshWorkItem = nil/);
const authenticated = section('} else if event == "authenticated"', 'private func handleAuthenticationRequired(');
assert.match(authenticated, /if isStarted \{\s+ensureFinancialRefreshScheduled\(\)/);
assert.doesNotMatch(authenticated, /if isStarted && !autoLoginInProgress/);
assert.match(source, /private static let financialRefreshInterval: TimeInterval = 20/);
console.log('PASS: financial scheduler recovery is wired to login, navigation and successful SMS without resetting permission blocks or duplicating pending work');
