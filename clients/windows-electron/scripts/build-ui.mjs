import { build } from 'esbuild';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const outputDirectory = path.join(root, 'build');
const sharedDirectory = path.resolve(root, '../shared');
await fs.rm(outputDirectory, { recursive: true, force: true });
await fs.mkdir(outputDirectory, { recursive: true });

await build({
  entryPoints: [
    path.join(root, 'src/ui/workbench.js'),
    path.join(root, 'src/ui/widget.js'),
    path.join(root, 'src/ui/detail.js')
  ],
  bundle: true,
  outdir: outputDirectory,
  format: 'iife',
  platform: 'browser',
  target: ['chrome140'],
  minify: false,
  sourcemap: false
});

for (const file of ['workbench.html', 'widget.html', 'detail.html', 'styles.css']) {
  await fs.copyFile(path.join(root, 'src/ui', file), path.join(outputDirectory, file));
}
await fs.copyFile(
  path.join(sharedDirectory, 'monitor-core.mjs'),
  path.join(outputDirectory, 'monitor-core.mjs')
);
