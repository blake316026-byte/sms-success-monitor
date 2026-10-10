import { build } from 'esbuild';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { queryScripts, nativeQueryFixture } from './query-scripts.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const outputDirectory = path.join(root, 'build');
const sharedDirectory = path.resolve(root, '../shared');
await fs.rm(outputDirectory, { recursive: true, force: true });
await fs.mkdir(outputDirectory, { recursive: true });

await build({
  entryPoints: [
    path.join(root, 'src/ui/workbench.js'),
    path.join(root, 'src/ui/reports.js')
  ],
  bundle: true,
  outdir: outputDirectory,
  format: 'iife',
  platform: 'browser',
  target: ['chrome140'],
  minify: false,
  sourcemap: false
});

for (const file of ['workbench.html', 'styles.css', 'reports.html', 'reports.css']) {
  await fs.copyFile(path.join(root, 'src/ui', file), path.join(outputDirectory, file));
}
await fs.writeFile(path.join(outputDirectory, 'query-scripts.json'), JSON.stringify(queryScripts()));
await fs.writeFile(path.join(outputDirectory, 'query-fixture.js'), nativeQueryFixture());
await fs.copyFile(
  path.join(sharedDirectory, 'monitor-core.mjs'),
  path.join(outputDirectory, 'monitor-core.mjs')
);
