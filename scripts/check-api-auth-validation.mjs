import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const read = (path) => fs.readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');

const mac = read('Sources/SMSMonitorApp/MonitorController.swift');
const macHandler = mac.slice(
  mac.indexOf('private func handleAPIAuthenticationRequired'),
  mac.indexOf('private func resetAccountIdentityRecovery')
);
assert.match(macHandler, /manualOnly[\s\S]*handleAuthenticationRequired/);
assert.match(macHandler, /apiAuthenticationValidationAttempted[\s\S]*reloadPlatformPage\(\)/);
assert.match(macHandler, /automatic login suppressed/);
assert.doesNotMatch(macHandler, /webView\.load\(URLRequest\(url: loginURL\)\)/);
assert.match(mac, /case "auth":[\s\S]*handleAPIAuthenticationRequired/);
assert.match(mac, /financial refresh requires authentication[\s\S]*handleAPIAuthenticationRequired/);

const windows = read('clients/windows-electron/src/main.mjs');
const windowsHandler = windows.slice(
  windows.indexOf('function handleAPIAuthenticationRequired'),
  windows.indexOf('function handleScanFailure')
);
assert.match(windowsHandler, /manualOnly[\s\S]*handleAuthenticationRequired/);
assert.match(windowsHandler, /apiAuthenticationValidationAttempted[\s\S]*webContents\.reload\(\)/);
assert.doesNotMatch(windowsHandler, /loadURL\(loginURLFor/);

const state = { monitoringEnabled: true };
let url = 'https://fixture.invalid/dashboard';
let reloads = 0, logins = 0;
const context = vm.createContext({
  moduleStates: new Map([['fixture', state]]),
  pages: new Map([['fixture', { view: { webContents: {
    getURL: () => url, reload: () => reloads++
  } } }]]),
  requiresInteractiveAuthentication: value => new URL(value).pathname === '/login',
  handleAuthenticationRequired: () => logins++,
  updateModule: (_, update) => Object.assign(state, update),
  SCAN_INTERVAL_MS: 60000,
});
vm.runInContext(windowsHandler, context);
for (const authCode of [0, 1010, 1011, 1013, 1014, 1013]) {
  context.handleAPIAuthenticationRequired('fixture', { authCode, httpStatus: 200 }, 'challenge');
}
assert.equal(reloads, 0);
assert.equal(logins, 0);
for (const result of [{ authCode: 1012 }, { httpStatus: 401 }, { authCode: 1012 }]) {
  context.handleAPIAuthenticationRequired('fixture', result, 'rejected');
}
assert.equal(reloads, 1, 'session rejection validates once, not once per polling channel');
assert.equal(logins, 0);
url = 'https://fixture.invalid/login';
context.handleAPIAuthenticationRequired('fixture', {}, 'login');
assert.equal(logins, 1);
const macScan = mac.slice(mac.indexOf('private func finishScan'), mac.indexOf('private func finishFinancialRefresh'));
assert.doesNotMatch(macScan, /apiAuthenticationValidationAttempted = false/,
  'successful SMS scans cannot rearm finance-triggered reloads');

const runtime = read('Sources/SMSMonitorApp/LocalAutomationRuntime.swift');
assert.match(runtime, /queuedCalls\.append[\s\S]*runNextCall\(\)/);
assert.match(runtime, /guard isReady, activeCallID == nil, !queuedCalls\.isEmpty/);
assert.match(runtime, /operationTimedOut[\s\S]*webView\.reload\(\)[\s\S]*asyncAfter\(deadline: \.now\(\) \+ 20/);
const loginPage = read('Sources/SMSMonitorApp/LoginPageAutomation.swift');
assert.match(loginPage, /pendingCalls: \[UUID: DispatchWorkItem\]/);
assert.match(loginPage, /pageOperationTimedOut[\s\S]*asyncAfter\(deadline: \.now\(\) \+ 15/);

console.log('PASS: API auth cannot force repeated login and local automation is serialized with timeout recovery');
