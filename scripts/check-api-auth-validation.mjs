import assert from 'node:assert/strict';
import fs from 'node:fs';

const read = (path) => fs.readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');

const mac = read('Sources/SMSMonitorApp/MonitorController.swift');
const macHandler = mac.slice(
  mac.indexOf('private func handleAPIAuthenticationRequired'),
  mac.indexOf('private func resetAccountIdentityRecovery')
);
assert.match(macHandler, /manualOnly[\s\S]*handleAuthenticationRequired/);
assert.match(macHandler, /apiAuthenticationValidationAttempted[\s\S]*webView\.reload\(\)/);
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
assert.match(windows, /result\.kind === 'auth'[\s\S]*handleAPIAuthenticationRequired/);
assert.match(windows, /result\?\.kind === 'auth'[\s\S]*handleAPIAuthenticationRequired/);

const runtime = read('Sources/SMSMonitorApp/LocalAutomationRuntime.swift');
assert.match(runtime, /queuedCalls\.append[\s\S]*runNextCall\(\)/);
assert.match(runtime, /guard isReady, activeCallID == nil, !queuedCalls\.isEmpty/);
assert.match(runtime, /operationTimedOut[\s\S]*webView\.reload\(\)[\s\S]*asyncAfter\(deadline: \.now\(\) \+ 20/);
const loginPage = read('Sources/SMSMonitorApp/LoginPageAutomation.swift');
assert.match(loginPage, /pendingCalls: \[UUID: DispatchWorkItem\]/);
assert.match(loginPage, /pageOperationTimedOut[\s\S]*asyncAfter\(deadline: \.now\(\) \+ 15/);

console.log('PASS: API auth cannot force repeated login and local automation is serialized with timeout recovery');
