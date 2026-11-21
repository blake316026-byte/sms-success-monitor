import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { windowsSigningPlan, verifyWindowsPackage } from './windows-signing.mjs';

const thumbprint = 'A'.repeat(40);
const env = { SMS_WINDOWS_CERTIFICATE_SHA1: thumbprint };
assert.throws(() => windowsSigningPlan({env:{}, platform:'win32', args:[]}), /Release blocked/);
assert.throws(() => windowsSigningPlan({env:{SMS_WINDOWS_CERTIFICATE_SHA1:'invalid'}, platform:'win32', args:[]}), /Release blocked/);
assert.throws(() => windowsSigningPlan({env, platform:'darwin', args:[]}), /must run on Windows/);
assert.throws(() => windowsSigningPlan({env, platform:'win32', args:['--skip-signing']}), /Only --unsigned-test/);
assert.throws(() => windowsSigningPlan({env:{}, args:['--unsigned-test','--unsigned-release']}), /Only/);
for (const name of ['WINDOWS_CERTIFICATE_FILE', 'WINDOWS_CERTIFICATE_PASSWORD', 'WINDOWS_SIGN_WITH_PARAMS', 'WINDOWS_SIGN_HOOK_MODULE_PATH']) {
  assert.throws(() => windowsSigningPlan({env:{...env,[name]:'conflicting'}, platform:'win32', args:[]}), /conflicting/);
}
const plan = windowsSigningPlan({env, platform:'win32', args:[]});
assert.deepEqual(plan.windowsSign.hashes, ['sha256']);
assert.equal(plan.windowsSign.automaticallySelectCertificate, false);
assert.equal(plan.windowsSign.continueOnError, false);
assert.deepEqual(plan.windowsSign.signWithParams, ['/sha1', thumbprint, '/s', 'My']);
assert.equal(plan.outputDirectory, 'windows');
assert.equal(plan.suffix, '');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sms-signing-test-'));
try {
  const unsigned = windowsSigningPlan({env:{},platform:'darwin',args:['--unsigned-test']});
  assert.equal(unsigned.outputDirectory, 'windows-test');
  assert.equal(unsigned.suffix, '-unsigned-test');
  assert.equal(unsigned.windowsSign, undefined);
  const rejected = verifyWindowsPackage(root, unsigned, {run:()=>{throw new Error('Must not invoke signer');}});
  assert.equal(rejected.releaseAllowed, false);
  assert.ok(fs.existsSync(path.join(root, 'UNSIGNED-TEST-ONLY.txt')));
  const release = windowsSigningPlan({env:{}, platform:'darwin', args:['--unsigned-release']});
  assert.equal(release.outputDirectory, 'windows');
  assert.equal(release.suffix, '');
  assert.equal(release.windowsSign, undefined);
  assert.throws(() => verifyWindowsPackage(root, release), /Test-only/);
  fs.rmSync(path.join(root, 'UNSIGNED-TEST-ONLY.txt'));
  assert.throws(() => verifyWindowsPackage(root, release), /Incomplete/);
  fs.mkdirSync(path.join(root, 'resources'));
  fs.writeFileSync(path.join(root, 'SMS Success Monitor.exe'), 'fixture-exe');
  fs.writeFileSync(path.join(root, 'resources/app.asar'), 'fixture-asar');
  const unsignedReport = verifyWindowsPackage(root, release, {run:()=>{throw new Error('Must not invoke signer');}});
  assert.equal(unsignedReport.status, 'UNSIGNED_RELEASE');
  assert.equal(unsignedReport.releaseAllowed, true);
  assert.equal(unsignedReport.publisherSignatureVerified, false);
  assert.equal(unsignedReport.fileCount, 2);
  assert.ok(unsignedReport.files.every(file => /^[a-f0-9]{64}$/.test(file.sha256)));
  fs.writeFileSync(path.join(root, 'resources/app.asar'), 'changed-fixture');
  assert.notDeepEqual(verifyWindowsPackage(root, release).files, unsignedReport.files);
  assert.throws(() => verifyWindowsPackage(root, plan, {platform:'darwin'}), /requires Windows/);
  const report = {status:'VERIFIED',releaseAllowed:true,expectedThumbprint:thumbprint,fileCount:1,files:[{path:'SMS Success Monitor.exe'}]};
  const run = (command,args,options) => {
    assert.equal(command, 'powershell.exe');
    assert.ok(args.includes('-NoProfile') && args.includes('-NonInteractive'));
    assert.ok(!args.includes('-ExecutionPolicy'));
    assert.equal(args.at(-1),thumbprint);
    assert.equal(options.encoding,'utf8');
    return JSON.stringify(report);
  };
  assert.deepEqual(verifyWindowsPackage(root,plan,{run,platform:'win32'}),report);
  assert.throws(() => verifyWindowsPackage(root,plan,{platform:'win32',run:()=>{throw new Error('Untrusted');}}), /Untrusted/);
  assert.throws(() => verifyWindowsPackage(root,plan,{platform:'win32',run:()=>'{invalid'}));
  for (const override of [{status:'UNSIGNED'}, {releaseAllowed:false}, {fileCount:0}, {files:[]}, {expectedThumbprint:'B'.repeat(40)}]) {
    assert.throws(() => verifyWindowsPackage(root,plan,{platform:'win32',run:()=>JSON.stringify({...report,...override})}), /Release blocked/);
  }
  const script = fs.readFileSync(new URL('./verify-windows-signature.ps1',import.meta.url),'utf8');
  for (const check of ['Get-AuthenticodeSignature','TimeStamperCertificate','1.3.6.1.5.5.7.3.3','UNSIGNED-TEST-ONLY.txt','ReparsePoint','Get-FileHash']) assert.ok(script.includes(check),check);
  const packageScript = fs.readFileSync(new URL('./package-windows.mjs',import.meta.url),'utf8');
  assert.ok(packageScript.indexOf('windowsSigningPlan()') < packageScript.indexOf('await packager('));
  assert.ok(packageScript.indexOf('verifyWindowsPackage(appPaths[0]') < packageScript.indexOf('const zipPath'));
  assert.ok(packageScript.includes('windowsSign: signing.windowsSign'));
  assert.ok(packageScript.includes('signing.outputDirectory') && packageScript.includes('signing.suffix'));
  console.log('PASS: explicit unsigned release inventory; test-only packages rejected; optional trusted signing fails closed');
} finally { fs.rmSync(root,{recursive:true,force:true}); }
