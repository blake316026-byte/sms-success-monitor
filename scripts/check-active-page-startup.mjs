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
  section('func start(after delay', 'private func beginConnection'),
  /let startupID = UUID\(\)[\s\S]*self\.startupID = startupID[\s\S]*self\.startupID == startupID/
);
assert.match(
  section('private func expediteStartupIfNeeded', 'private func beginConnection'),
  /startupID != nil[\s\S]*startupWorkItem\?\.cancel\(\)[\s\S]*beginConnection\(\)/
);
assert.match(
  section('func setPageActive', 'func scanNow'),
  /if active \{[\s\S]*expediteStartupIfNeeded\(\)/
);
assert.match(
  section('func credentialsDidChange', 'fileprivate func handleSessionLifecycle'),
  /guard monitoringEnabled[\s\S]*expediteStartupIfNeeded\(\)/
);

console.log('PASS: selecting a queued page or saving its credentials starts it immediately');
