import assert from 'node:assert/strict';
import fs from 'node:fs';
const root = new URL('../', import.meta.url);
const read = file => fs.readFileSync(new URL(file, root), 'utf8');
for (const file of [
  'Sources/SMSMonitorApp/StatusWidgetController.swift',
  'Sources/SMSMonitorApp/AlertNotifier.swift',
  'clients/windows-electron/src/ui/widget.html',
  'clients/windows-electron/src/ui/detail.html',
  'clients/android/app/src/main/java/com/local/smssuccessmonitor/GaugeView.java',
  'clients/android/app/src/main/java/com/local/smssuccessmonitor/BootReceiver.java'
]) assert.equal(fs.existsSync(new URL(file, root)), false, file);
const delegate = read('Sources/SMSMonitorApp/AppDelegate.swift');
assert.doesNotMatch(delegate, /StatusWidget|AlertNotifier|refreshWidget/);
assert.match(delegate, /applicationShouldHandleReopen/);
const monitor = read('Sources/SMSMonitorApp/MonitorController.swift');
assert.match(monitor, /func start\(after delay:[\s\S]*?\{\s*startAuthenticationOnly\(\)\s*\}/);
assert.doesNotMatch(monitor, /monitoringEnabled = true|smsMonitoringEnabled = smsEnabled|financialMonitoringEnabled = financeEnabled/);
const workspace = read('Sources/SMSMonitorApp/PlatformWorkspaceController.swift');
assert.doesNotMatch(workspace, /case ToolbarIdentifier.sampleLimit:|ToolbarIdentifier.sampleLimit,/);
assert.match(workspace, /case ToolbarIdentifier.pendingOrders:/);
assert.match(workspace, /case ToolbarIdentifier.withdrawalReviewers:/);
assert.match(read('Resources/Info.plist'), /com.local.sms-success-monitor.public/);
assert.match(read('Sources/SMSMonitorApp/WithdrawalReviewersCache.swift'), /SMS Platform Workbench\/withdrawal-reviewers/);
assert.match(read('Sources/SMSMonitorApp/LocalCredentialStore.swift'), /appendingPathComponent\("SMS Platform Workbench"/);
const windows = read('clients/windows-electron/src/main.mjs');
assert.doesNotMatch(windows, /createWidgetWindow|createDetailWindow|widgetWindow|detailWindow|dailyFinancialTotals|smsMonitorFinance|smsMonitorScan/);
assert.doesNotMatch(windows, /scanTimer = setInterval|financeTimer = setInterval/);
assert.match(windows, /setPath\('userData',[^\n]*SMS Platform Workbench/);
const android = 'clients/android/app/src/main/';
const manifest = read(android + 'AndroidManifest.xml');
assert.doesNotMatch(manifest, /SYSTEM_ALERT_WINDOW|POST_NOTIFICATIONS|FOREGROUND_SERVICE|RECEIVE_BOOT_COMPLETED|BootReceiver/);
assert.doesNotMatch(read(android + 'java/com/local/smssuccessmonitor/MainActivity.java'), /showOverview|toggleOverlay|overviewDialog|startForegroundService/);
assert.doesNotMatch(read(android + 'java/com/local/smssuccessmonitor/MonitorService.java'), /GaugeView|createOverlay|startForeground\(|Notification.Builder|smsMonitorScan|periodicScan/);
assert.match(read('clients/android/app/build.gradle'), /applicationId 'com.local.smssuccessmonitor.publicworkbench'/);
console.log('PASS: public clients remove monitor surfaces, polling, IPC and use isolated storage');
