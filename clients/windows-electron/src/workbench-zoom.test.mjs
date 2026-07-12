import assert from 'node:assert/strict';
import {
  DEFAULT_WORKBENCH_ZOOM_FACTOR,
  MAX_WORKBENCH_ZOOM_FACTOR,
  MIN_WORKBENCH_ZOOM_FACTOR,
  nextWorkbenchZoomFactor,
  normalizeWorkbenchZoomFactor
} from './workbench-zoom.mjs';

assert.equal(normalizeWorkbenchZoomFactor('invalid'), DEFAULT_WORKBENCH_ZOOM_FACTOR);
assert.equal(normalizeWorkbenchZoomFactor(1.24), 1.25);
assert.equal(nextWorkbenchZoomFactor(1, 'in'), 1.1);
assert.equal(nextWorkbenchZoomFactor(1, 'out'), 0.9);
assert.equal(nextWorkbenchZoomFactor(1.5, 'reset'), 1);
assert.equal(nextWorkbenchZoomFactor(MAX_WORKBENCH_ZOOM_FACTOR, 'in'), 2);
assert.equal(nextWorkbenchZoomFactor(MIN_WORKBENCH_ZOOM_FACTOR, 'out'), 0.5);

console.log('Windows workbench zoom checks passed');
