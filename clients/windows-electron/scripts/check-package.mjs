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
console.log('Windows Electron package structure checks passed');
