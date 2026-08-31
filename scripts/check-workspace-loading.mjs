import assert from 'node:assert/strict';
import fs from 'node:fs';

const source = fs.readFileSync(
  new URL('../Sources/SMSMonitorApp/PlatformWorkspaceController.swift', import.meta.url),
  'utf8'
);
const section = (from, to) => {
  const start = source.indexOf(from);
  const end = source.indexOf(to, start + from.length);
  assert(start >= 0 && end > start, `missing source section ${from}`);
  return source.slice(start, end);
};

assert.doesNotMatch(
  section('private func restoreWorkspaceLayout()', 'private func restoreLegacyAdditionalPages()'),
  /page\.webView\.load/,
  'restoring the workspace must not start every custom page at once'
);
assert.match(
  section('private func applySelectedPagePerformanceMode()', 'private func updateToolbar()'),
  /ensureSelectedPageLoaded\(\)[\s\S]*page\.webView\.url == nil[\s\S]*page\.webView\.load/,
  'selecting an unloaded page must load it immediately'
);
assert.match(
  section('private func createAdditionalPage(', 'private var selectedPage:'),
  /if select \{ ensureSelectedPageLoaded\(\) \}/,
  'a newly created selected page must load without waiting for its monitor'
);

console.log('PASS: restored custom pages load on selection or monitor start instead of all loading concurrently');
