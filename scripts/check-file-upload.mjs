import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
const root = path.resolve(import.meta.dirname, '..');
const source = fs.readFileSync(path.join(root, 'Sources/SMSMonitorApp/PlatformWorkspaceController.swift'), 'utf8');
const method = source.match(/  func webView\(\s*_ webView: WKWebView,\s*runOpenPanelWith[\s\S]+?\n  \}/)?.[0];
assert(method && method.includes('PlatformFileUploadPanel.present'), 'Production file-upload callback is missing');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'sms-upload-check-'));
try {
  const delegate = path.join(temp, 'ProductionUploadDelegate.swift');
  fs.writeFileSync(delegate, 'import AppKit\nimport WebKit\nfinal class ProductionUploadDelegate: NSObject, WKUIDelegate {\n' + method + '\n}\n');
  const binary = path.join(temp, 'check');
  execFileSync('swiftc', ['-parse-as-library', path.join(root,'Sources/SMSMonitorApp/PlatformFileUploadPanel.swift'), delegate, path.join(root,'scripts/FileUploadWebKitCheck.swift'), '-o', binary], {stdio:'inherit'});
  execFileSync(binary, [], {stdio:'inherit', timeout:60000});
} finally { fs.rmSync(temp, {recursive:true, force:true}); }
