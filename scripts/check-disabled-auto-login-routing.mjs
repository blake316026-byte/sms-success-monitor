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
  /guard !monitoringEnabled[\s\S]*scheduleAuthenticationOnlyDetection\(\)[\s\S]*requiresAuthentication[\s\S]*resumeAuthenticationOnlyIfNeeded[\s\S]*identifyPlatform/
);
assert.match(
  section('private func requiresInteractiveAuthentication', 'private func isMonitorOrigin'),
  /requiresAuthentication\(url\)[\s\S]*resumeAuthenticationOnlyIfNeeded[\s\S]*guard isStarted, !monitoringEnabled[\s\S]*requiresAuthentication[\s\S]*handleAuthenticationRequired/
);
assert.match(
  section('private func identifyPlatform', 'private func scheduleAuthenticationOnlyDetection'),
  /else if self\.monitoringEnabled[\s\S]*PlatformRoutingPolicy\.shouldUseNPGMonitoring[\s\S]*continueNPG\(\)[\s\S]*enterBrowserOnlyMode\(\)[\s\S]*else[\s\S]*continueNPG\(\)/
);
assert.match(
  section('private func scheduleAuthenticationOnlyDetection', 'private func enterBrowserOnlyMode'),
  /guard let self, self\.isStarted, !self\.monitoringEnabled[\s\S]*requiresAuthentication\(url\)[\s\S]*!self\.autoLoginInProgress[\s\S]*resumeAuthenticationOnlyIfNeeded\(\)[\s\S]*scheduleAuthenticationOnlyDetection\(\)/
);
assert.match(
  section('func scanNow()', 'func updateSampleLimit'),
  /guard isStarted, monitoringEnabled[\s\S]*if !smsMonitoringEnabled[\s\S]*handleAuthenticationRequired[\s\S]*guard !isScanning[\s\S]*ScanScript\.body/
);
assert.match(
  section('private func scheduleFinancialRefresh', 'private func finishFinancialRefresh'),
  /guard isStarted, monitoringEnabled, financialMonitoringEnabled[\s\S]*guard monitoringEnabled, financialMonitoringEnabled[\s\S]*FinanceScript\.body[\s\S]*financialRequestID == requestID/
);
assert.match(
  section('private func applyActivePage', 'private func updatePage'),
  /disabledModuleIDs\.contains\(monitorID\)[\s\S]*disabledFinancialModuleIDs\.contains\(monitorID\)[\s\S]*startAuthenticationOnly\(\)[\s\S]*stopAuthenticationOnly\(\)/
);
assert.match(
  section('func setMonitoringEnabled', 'private func persistDisabledModuleIDs'),
  /setFinancialMonitoringEnabled[\s\S]*disabledModuleIDs[\s\S]*disabledFinancialModuleIDs[\s\S]*monitor\.updateMonitoringModes[\s\S]*!smsEnabled && !financeEnabled[\s\S]*startAuthenticationOnly\(\)/
);
assert.match(
  section('func webView(_ webView', 'didFailProvisionalNavigation'),
  /!monitoringEnabled, requiresAuthentication\(url\)[\s\S]*resumeAuthenticationOnlyIfNeeded\(\)[\s\S]*browserOnlyPage/
);
assert.match(
  section('fileprivate func handleSessionLifecycle', 'private func prepareAuthenticationRecovery'),
  /guard monitoringEnabled/
);

const windows = fs.readFileSync(
  new URL('../clients/windows-electron/src/main.mjs', import.meta.url), 'utf8'
);
assert.match(windows, /pausedFinanceIds = new Set\([\s\S]*?stored\?\.pausedFinanceIds[\s\S]*?pausedMonitorIds/);
assert.match(windows, /async function scanModule[\s\S]*?!state\.monitoringEnabled/);
assert.match(windows, /async function refreshFinancialModule[\s\S]*?!state\.financeEnabled[\s\S]*?financeGeneration !== generation/);
assert.match(windows, /monitor:set-finance-enabled[\s\S]*?state\.financeGeneration \+= 1[\s\S]*?state\.dailyFinancial = null/);
assert.match(windows, /monitor:set-enabled[\s\S]*?state\.monitoringEnabled = nextEnabled/);
const detail = fs.readFileSync(
  new URL('../clients/windows-electron/src/ui/detail.html', import.meta.url), 'utf8'
);
assert.match(detail, /id="monitor-enabled"[\s\S]*?id="finance-enabled"/);

console.log('PASS: SMS and finance run independently; a fully disabled selected page may auto-login');
