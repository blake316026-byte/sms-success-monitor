import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import {
  calculateMetrics,
  isAlert,
  MAX_SAMPLE_LIMIT,
  MIN_SAMPLE_LIMIT,
  normalizeSampleLimit,
  percentageText,
  selectFocus,
  shouldReloadAfterFailure
} from './monitor-core.mjs';

const modulesPath = fileURLToPath(new URL('./modules.json', import.meta.url));
const modules = JSON.parse(fs.readFileSync(modulesPath, 'utf8'));
assert.equal(modules.length, 9);
assert.equal(new Set(modules.map((module) => module.id)).size, 9);
assert.equal(new Set(modules.map((module) => new URL(module.url).host)).size, 9);

const low = calculateMetrics([
  ...Array(69).fill('SUCCESS'),
  ...Array(131).fill('SENT')
]);
assert.equal(percentageText(low), '34.5%');
assert.equal(isAlert(low), true);

const focus = selectFocus([
  { id: 'logged', status: 'healthy', metrics: calculateMetrics(Array(126).fill('SUCCESS').concat(Array(74).fill('SENT'))), alertThreshold: 0.5 },
  { id: 'unauthenticated', status: 'auth', metrics: null, alertThreshold: 0.5 }
]);
assert.equal(focus.id, 'logged');

const lowestAlert = selectFocus([
  { id: 'a', status: 'alert', metrics: low, alertThreshold: 0.5 },
  { id: 'b', status: 'alert', metrics: calculateMetrics(Array(82).fill('SUCCESS').concat(Array(118).fill('SENT'))), alertThreshold: 0.5 }
]);
assert.equal(lowestAlert.id, 'a');

assert.equal(shouldReloadAfterFailure(1), false);
assert.equal(shouldReloadAfterFailure(2), true);
assert.equal(normalizeSampleLimit('75'), 75);
assert.equal(normalizeSampleLimit(1), MIN_SAMPLE_LIMIT);
assert.equal(normalizeSampleLimit(10_000), MAX_SAMPLE_LIMIT);
assert.equal(normalizeSampleLimit('invalid'), 200);

console.log('All shared cross-platform checks passed');
