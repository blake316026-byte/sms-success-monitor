import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

const verifier = fileURLToPath(new URL('./verify-windows-signature.ps1', import.meta.url));

export function windowsSigningPlan({ env = process.env, platform = process.platform, args = process.argv.slice(2) } = {}) {
  if (args.some(arg => !['--unsigned-test', '--unsigned-release'].includes(arg)) || args.length > 1) {
    throw new Error('Only --unsigned-test or --unsigned-release is accepted.');
  }
  if (args.includes('--unsigned-release')) {
    return { testOnly: false, unsignedRelease: true, outputDirectory: 'windows', suffix: '', windowsSign: undefined };
  }
  if (args.includes('--unsigned-test')) {
    return { testOnly: true, outputDirectory: 'windows-test', suffix: '-unsigned-test', windowsSign: undefined };
  }
  const thumbprint = (env.SMS_WINDOWS_CERTIFICATE_SHA1 || '').replace(/\s/g, '').toUpperCase();
  if (!/^[0-9A-F]{40}$/.test(thumbprint)) {
    throw new Error('Release blocked: set SMS_WINDOWS_CERTIFICATE_SHA1 to your validated code-signing certificate thumbprint. Use --unsigned-test only for isolated tests.');
  }
  if (platform !== 'win32') {
    throw new Error('Release signing and trust verification must run on Windows with the enrolled signing certificate.');
  }
  // Pin one certificate. Do not let inherited Electron settings select another signer.
  for (const name of ['WINDOWS_CERTIFICATE_FILE', 'WINDOWS_CERTIFICATE_PASSWORD', 'WINDOWS_SIGN_WITH_PARAMS', 'WINDOWS_SIGN_HOOK_MODULE_PATH']) {
    if (env[name]) throw new Error('Release blocked: remove conflicting ' + name + '. Use the enrolled Windows certificate store.');
  }
  return {
    testOnly: false, outputDirectory: 'windows', suffix: '', thumbprint,
    windowsSign: {
      automaticallySelectCertificate: false,
      hashes: ['sha256'],
      signWithParams: ['/sha1', thumbprint, '/s', 'My'],
      timestampServer: 'http://ts.ssl.com',
      continueOnError: false
    }
  };
}

export function verifyWindowsPackage(appDirectory, plan, { run = execFileSync, platform = process.platform } = {}) {
  if (plan.unsignedRelease) {
    if (fs.existsSync(path.join(appDirectory, 'UNSIGNED-TEST-ONLY.txt'))) {
      throw new Error('Test-only package cannot be published.');
    }
    const files = [];
    const visit = (directory) => {
      for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
        const file = path.join(directory, entry.name);
        if (entry.isSymbolicLink()) throw new Error('Package contains a link.');
        if (entry.isDirectory()) visit(file);
        else if (entry.isFile() && file !== path.join(appDirectory, 'WINDOWS-SIGNATURE.json')) {
          files.push({ path: path.relative(appDirectory, file).split(path.sep).join('/'),
            sha256: createHash('sha256').update(fs.readFileSync(file)).digest('hex') });
        } else if (!entry.isFile()) throw new Error('Unsupported package entry.');
      }
    };
    visit(appDirectory);
    for (const required of ['SMS Success Monitor.exe', 'resources/app.asar']) {
      if (!files.some(file => file.path === required)) throw new Error('Incomplete package: ' + required);
    }
    files.sort((a, b) => a.path.localeCompare(b.path));
    return { status: 'UNSIGNED_RELEASE', releaseAllowed: true, publisherSignatureVerified: false,
      fileCount: files.length, files };
  }
  if (plan.testOnly) {
    const report = { status: 'UNSIGNED_TEST_ONLY', releaseAllowed: false };
    fs.writeFileSync(path.join(appDirectory, 'UNSIGNED-TEST-ONLY.txt'),
      'Local test build only. Not signed or approved for public release. Do not disable Windows security to run it.\n');
    return report;
  }
  if (platform !== 'win32' || !/^[0-9A-F]{40}$/.test(plan.thumbprint || '')) {
    throw new Error('Windows signature verification requires Windows and a pinned certificate.');
  }
  const output = run('powershell.exe', [
    '-NoLogo', '-NoProfile', '-NonInteractive', '-File', verifier,
    '-AppDirectory', path.resolve(appDirectory), '-ExpectedThumbprint', plan.thumbprint
  ], { encoding: 'utf8', timeout: 300000, maxBuffer: 4 * 1024 * 1024 });
  const report = JSON.parse(output.replace(/^\uFEFF/, '').trim());
  if (report.status !== 'VERIFIED' || report.releaseAllowed !== true ||
      report.expectedThumbprint !== plan.thumbprint || !Number.isInteger(report.fileCount) ||
      report.fileCount < 1 || !Array.isArray(report.files) || report.files.length !== report.fileCount) {
    throw new Error('Release blocked: missing or incomplete Windows signature verification.');
  }
  return report;
}
