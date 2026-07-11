import { packager } from '@electron/packager';
import { ZipArchive } from 'archiver';
import fs from 'node:fs';
import fsPromises from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const clientRoot = path.resolve(projectRoot, '../..');
const outputRoot = path.join(clientRoot, 'dist/windows');
const packageOutput = path.join(projectRoot, '.package-output');
const sharedRoot = path.resolve(projectRoot, '../shared');

await fsPromises.rm(packageOutput, { recursive: true, force: true });
await fsPromises.mkdir(outputRoot, { recursive: true });

const appPaths = await packager({
  dir: projectRoot,
  name: 'SMS Success Monitor',
  platform: 'win32',
  arch: 'x64',
  electronVersion: '43.1.0',
  out: packageOutput,
  overwrite: true,
  asar: true,
  prune: true,
  extraResource: [sharedRoot],
  ignore: [
    /^\/\.package-output($|\/)/,
    /^\/scripts($|\/)/,
    /^\/src\/ui($|\/)/,
    /^\/package-lock\.json$/
  ]
});

const zipPath = path.join(outputRoot, 'SMS-Success-Monitor-Windows-x64.zip');
await fsPromises.rm(zipPath, { force: true });
await new Promise((resolve, reject) => {
  const output = fs.createWriteStream(zipPath);
  const archive = new ZipArchive({ zlib: { level: 9 } });
  output.on('close', resolve);
  archive.on('error', reject);
  archive.pipe(output);
  archive.directory(appPaths[0], 'SMS Success Monitor');
  archive.finalize();
});

await fsPromises.rm(packageOutput, { recursive: true, force: true });

console.log(zipPath);
