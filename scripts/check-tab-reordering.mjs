import assert from 'node:assert/strict';
import fs from 'node:fs';

const source = fs.readFileSync(
  new URL('../Sources/SMSMonitorApp/PlatformWorkspaceController.swift', import.meta.url),
  'utf8'
);

const start = source.indexOf('private final class WrappingTabBarView');
const end = source.indexOf('private final class WorkspaceContainerController', start);
assert(start >= 0 && end > start, 'missing wrapping tab bar implementation');
const tabBar = source.slice(start, end);

const changedStart = tabBar.indexOf('case .changed:');
const endedStart = tabBar.indexOf('case .ended:', changedStart);
assert(changedStart >= 0 && endedStart > changedStart, 'missing drag state handling');
const changed = tabBar.slice(changedStart, endedStart);

assert.match(changed, /previewMove\(from: source, to: target\)/,
  'drag updates should preview the new order');
assert.doesNotMatch(changed, /onMove\?\(/,
  'drag updates must not commit and persist every crossed tab');
assert.match(tabBar, /case \.ended:[\s\S]*finishTabDrag\(commit: true\)/,
  'the tab order should commit once when the pointer is released');
assert.match(tabBar, /existing\[ObjectIdentifier\(item\)\] \?\? makeButton/,
  'tab synchronization should reuse controls instead of rebuilding them');
assert.match(tabBar, /buttons\.remove\(at: source\)[\s\S]*buttons\.insert\(button, at: target\)/,
  'drag previews should reorder the lightweight button array');

console.log('PASS: wrapped platform tabs preview during drag and commit once on release');
