import fs from 'node:fs';
import assert from 'node:assert/strict';

const source = fs.readFileSync(new URL('../Sources/SMSMonitorApp/MonitorController.swift', import.meta.url), 'utf8');
const section = (start, end) => {
  const a = source.indexOf(start);
  const b = source.indexOf(end, a + start.length);
  assert(a >= 0 && b > a);
  return source.slice(a, b);
};
assert.match(section('func scanNow()', 'func updateSampleLimit'), /identifyPlatform[\s\S]*ScanScript.body/);
assert.match(section('private func refreshFinancialMetricsNow()', 'private func finishFinancialRefresh'), /identifyPlatform[\s\S]*FinanceScript.body/);
assert.match(section('private func identifyPlatform', 'func webView(_ webView'), /PlatformRoutingPolicy\.shouldUseNPGMonitoring[\s\S]*enterBrowserOnlyMode/);
assert.match(section('private func enterBrowserOnlyMode', 'func webView(_ webView'), /cancelNextScan\(\)[\s\S]*financialRefreshWorkItem\?\.cancel\(\)[\s\S]*browserOnly/);
const native = fs.readFileSync(new URL('../Sources/SMSMonitorApp/TianchengLoginController.swift', import.meta.url), 'utf8');
assert.doesNotMatch(native, /ScanScript|FinanceScript|URLSession|URLRequest|load\(/);
assert.match(native, /self\.generation == epoch, self\.hasMatchingOrigin/);
assert.match(native, /submittedAt\) > 20/);
assert.match(native, /kind == "totp", self\.stage != "totp"/);
assert.match(native, /kind == "password", self\.stage\.isEmpty/);
console.log('PASS: platform routing precedes monitoring queries, isolates browser-only pages and never retries submitted Tiancheng login stages');
