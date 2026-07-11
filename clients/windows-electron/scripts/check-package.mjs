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
  'src/ui/detail.html'
]) {
  assert.equal(fs.existsSync(path.join(root, file)), true, `missing ${file}`);
}
console.log('Windows Electron package structure checks passed');
