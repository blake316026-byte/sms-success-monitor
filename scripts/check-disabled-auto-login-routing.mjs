import assert from 'node:assert/strict';
import fs from 'node:fs';

const source = fs.readFileSync(
  new URL('../Sources/SMSMonitorApp/MonitorController.swift', import.meta.url),
  'utf8'
);
const section = (from, to) => {
  const start = source.indexOf(from);
  const end = source.indexOf(to, start + from.length);
  assert(start >= 0 && end > start, `missing source section ${from}`);
  return source.slice(start, end);
};

assert.match(
  section('func startAuthenticationOnly()', 'func setPageActive'),
  /guard !monitoringEnabled[\s\S]*requiresAuthentication[\s\S]*resumeAuthenticationOnlyIfNeeded[\s\S]*identifyPlatform/
);
assert.match(
  section('private func requiresInteractiveAuthentication', 'private func isMonitorOrigin'),
  /resumeAuthenticationOnlyIfNeeded[\s\S]*guard isStarted, !monitoringEnabled[\s\S]*requiresAuthentication[\s\S]*handleAuthenticationRequired/
);
assert.match(
  section('private func identifyPlatform', 'private func scheduleAuthenticationOnlyDetection'),
  /else if self\.monitoringEnabled[\s\S]*PlatformRoutingPolicy\.shouldUseNPGMonitoring[\s\S]*continueNPG\(\)[\s\S]*enterBrowserOnlyMode\(\)[\s\S]*else[\s\S]*continueNPG\(\)/
);
assert.match(
  section('func scanNow()', 'func updateSampleLimit'),
  /guard isStarted, monitoringEnabled[\s\S]*ScanScript\.body/
);
assert.match(
  section('private func scheduleFinancialRefresh', 'private func finishFinancialRefresh'),
  /guard isStarted, monitoringEnabled[\s\S]*guard monitoringEnabled, !browserOnlyPage[\s\S]*FinanceScript\.body/
);
assert.match(
  section('private func applyActivePage', 'private func updatePage'),
  /disabledModuleIDs\.contains\(monitorID\)[\s\S]*startAuthenticationOnly\(\)[\s\S]*stopAuthenticationOnly\(\)/
);
assert.match(
  section('func setMonitoringEnabled', 'private func persistDisabledModuleIDs'),
  /monitor\.stop\(\)[\s\S]*selectedCredentialID == moduleID[\s\S]*startAuthenticationOnly\(\)/
);
assert.match(
  section('func webView(_ webView', 'didFailProvisionalNavigation'),
  /!monitoringEnabled, requiresAuthentication\(url\)[\s\S]*resumeAuthenticationOnlyIfNeeded\(\)[\s\S]*browserOnlyPage/
);
assert.match(
  section('fileprivate func handleSessionLifecycle', 'private func prepareAuthenticationRecovery'),
  /guard monitoringEnabled/
);

console.log('PASS: a selected disabled page may auto-login without running SMS, finance or alerts');
