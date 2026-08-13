import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
for (const file of [
  'src/main.mjs',
  'src/preload.cjs',
  'src/ui/workbench.html',
  'src/ui/widget.html',
  'src/ui/detail.html',
  '../shared/auto-login/runtime.html',
  '../shared/auto-login/runtime.js',
  '../shared/auto-login/login-page.js',
  '../shared/auto-login/common_old.onnx',
  '../shared/auto-login/vendor/ort.wasm.min.js',
  '../shared/auto-login/vendor/ort-wasm-simd-threaded.mjs',
  '../shared/auto-login/vendor/ort-wasm-simd-threaded.wasm'
]) {
  assert.equal(fs.existsSync(path.join(root, file)), true, `missing ${file}`);
}

const mainSource = fs.readFileSync(path.join(root, 'src/main.mjs'), 'utf8');
const preloadSource = fs.readFileSync(path.join(root, 'src/preload.cjs'), 'utf8');
const workbenchSource = fs.readFileSync(path.join(root, 'src/ui/workbench.html'), 'utf8');
const workbenchScript = fs.readFileSync(path.join(root, 'src/ui/workbench.js'), 'utf8');
assert.match(mainSource, /settings:set-sample-limit/, 'main process exposes local sample settings');
assert.match(mainSource, /monitor-settings\.json/, 'sample settings persist in the local user directory');
assert.match(preloadSource, /setSampleLimit/, 'preload exposes the sample setting command');
assert.match(workbenchSource, /id="sample-limit"/, 'workbench renders the sample count input');
assert.match(mainSource, /workbench:zoom/, 'main process exposes workbench zoom controls');
assert.match(mainSource, /workbenchZoomFactor/, 'workbench zoom persists in local settings');
assert.match(preloadSource, /changeWorkbenchZoom/, 'preload exposes workbench zoom commands');
assert.match(mainSource, /workbench:modal/, 'main process controls the workbench modal layer');
assert.match(mainSource, /function setWorkbenchModalOpen/, 'modal layer detaches the remote page view');
assert.match(preloadSource, /setWorkbenchModalOpen/, 'preload exposes workbench modal visibility');
assert.match(workbenchScript, /showWorkbenchDialog/, 'renderer hides the remote page before opening dialogs');
assert.match(workbenchScript, /openingDialog/, 'renderer prevents overlapping dialog open requests');
assert.match(mainSource, /workbenchWindow\.webContents\.focus\(\)/, 'main process returns keyboard focus from the remote page');
assert.match(workbenchScript, /requestAnimationFrame/, 'dialog waits for rendering before focusing its input');
assert.match(workbenchScript, /initialFocus\?\.focus\(\)/, 'dialog explicitly focuses its first input');
assert.match(workbenchSource, /id="page-name" required autofocus/, 'add dialog provides a native autofocus fallback');
assert.match(workbenchScript, /addEventListener\('close', restoreWorkbenchView\)/, 'renderer restores the page after dialogs close');
assert.doesNotMatch(workbenchScript, /closeButton\.disabled = selected\.monitored/, 'built-in platforms can be removed locally');
assert.doesNotMatch(workbenchScript, /renameButton\.disabled = selected\.monitored/, 'built-in platforms can be renamed locally');
assert.doesNotMatch(workbenchScript, /window\.prompt/, 'rename uses the focus-safe workbench dialog');
assert.match(workbenchSource, /id="rename-dialog"/, 'workbench renders a rename dialog');
assert.match(mainSource, /moduleDisplayNames\[id\] = name/, 'renamed built-in platforms persist locally');
assert.match(mainSource, /moduleDisplayNames\[module\.id\] \|\| module\.name/, 'renamed built-in platforms restore after restart');
assert.match(workbenchScript, /window\.confirm/, 'platform removal requires confirmation');
assert.match(mainSource, /disabledModuleIds\.add\(id\)/, 'removed built-in platforms persist locally');
assert.match(mainSource, /disabledModuleIds\.delete\(id\)/, 'failed persistence restores the built-in platform state');
assert.match(mainSource, /if \(!disabledModuleIds\.has\(module\.id\)\)/, 'removed built-in platforms stay removed after restart');
assert.match(workbenchSource, /id="zoom-out"/, 'workbench renders zoom out');
assert.match(workbenchSource, /id="zoom-reset"/, 'workbench renders the zoom percentage');
assert.match(workbenchSource, /id="zoom-in"/, 'workbench renders zoom in');
assert.match(mainSource, /findInPage/, 'main process searches the selected backend page');
assert.match(mainSource, /found-in-page/, 'main process forwards find result counts');
assert.match(preloadSource, /findInPage/, 'preload exposes page find commands');
assert.match(workbenchSource, /id="find-bar"/, 'workbench renders the page find bar');
assert.match(workbenchSource, /id="find-previous"/, 'workbench renders previous match');
assert.match(workbenchSource, /id="find-next"/, 'workbench renders next match');
assert.match(mainSource, /function ensurePageState/, 'custom pages receive local auto-login state');
assert.match(
  mainSource,
  /const moduleList = \[\.\.\.pages\.values\(\)\]\.map/,
  'custom pages are included in the monitoring overview'
);
assert.match(mainSource, /function scanAllPages/, 'all-page scanning includes custom pages');
assert.match(mainSource, /financialRefreshIntervalMs = 20_000/, 'Windows refreshes finance independently every 20 seconds');
assert.match(mainSource, /financePermissionBlocked/, 'Windows stops finance requests after a permission denial');
assert.match(mainSource, /smsPermissionBlocked/, 'Windows stops SMS requests after a permission denial');
assert.match(mainSource, /dailyFinancialTotals/, 'Windows aggregates available financial totals');
assert.match(mainSource, /reloadIgnoringCache/, 'manual refresh reloads the selected platform without cache');
assert.match(mainSource, /setTimeout\(\(\) => refreshFinancialModule\(page\.id\), 900\)/, 'page refresh triggers an immediate finance refresh');
assert.match(mainSource, /state\.smsPermissionBlocked = false/, 'manual refresh clears the SMS permission circuit breaker');
assert.match(workbenchScript, /const result = await window\.smsApi\.reload\(\)/, 'refresh button awaits the main-process result');
assert.match(workbenchSource.replace('workbench', 'workbench'), /id="rename-dialog"/, 'workbench keeps rename support');
assert.doesNotMatch(
  workbenchScript,
  /credentialsButton\.disabled = !selected\.monitored/,
  'custom pages keep the auto-login button enabled'
);
assert.doesNotMatch(
  workbenchScript,
  /selected\?\.monitored \? selected\.id : null/,
  'custom pages can be scanned directly from the workbench'
);
console.log('Windows Electron package structure checks passed');
