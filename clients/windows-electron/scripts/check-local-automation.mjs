import { app, BrowserWindow, safeStorage } from 'electron';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptsDirectory = path.dirname(fileURLToPath(import.meta.url));
const sharedDirectory = path.resolve(scriptsDirectory, '../../shared');
const fixture = fs.readFileSync(
  path.join(sharedDirectory, 'auto-login/fixtures/nRVr.jpg')
).toString('base64');
const pathToken = crypto.randomUUID();

function contentType(filePath) {
  return {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.mjs': 'text/javascript; charset=utf-8',
    '.wasm': 'application/wasm'
  }[path.extname(filePath)] || 'application/octet-stream';
}

const server = http.createServer((request, response) => {
  let requestPath = '';
  try {
    requestPath = decodeURIComponent(new URL(request.url, 'http://127.0.0.1').pathname);
  } catch (_) {
    response.writeHead(400).end();
    return;
  }
  const prefix = `/${pathToken}/`;
  const relativePath = requestPath.startsWith(prefix) ? requestPath.slice(prefix.length) : '';
  const filePath = path.resolve(sharedDirectory, 'auto-login', relativePath);
  const root = path.resolve(sharedDirectory, 'auto-login');
  if (!relativePath || !filePath.startsWith(`${root}${path.sep}`)) {
    response.writeHead(404).end();
    return;
  }
  const stream = fs.createReadStream(filePath);
  stream.once('error', () => response.writeHead(404).end());
  stream.once('open', () => {
    response.writeHead(200, { 'Content-Type': contentType(filePath) });
    stream.pipe(response);
  });
});

app.commandLine.appendSwitch('disable-gpu');
const watchdog = setTimeout(() => {
  console.error('Local automation self-test exceeded 90 seconds');
  app.exit(1);
}, 90_000);
let automationWindow;
let exitCode = 0;

try {
  await app.whenReady();
  assert.equal(safeStorage.isEncryptionAvailable(), true);
  const encryptedSecret = safeStorage.encryptString('local-only');
  assert.equal(safeStorage.decryptString(encryptedSecret), 'local-only');
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const address = server.address();
  automationWindow = new BrowserWindow({
    show: false,
    webPreferences: {
      backgroundThrottling: false,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  });
  automationWindow.webContents.on('console-message', (_event, details) => {
    console.error(`[runtime:${details.level}] ${details.message}`);
  });
  automationWindow.webContents.on('did-fail-load', (_event, code, description, url) => {
    console.error(`Runtime page failed to load: ${code} ${description} ${url}`);
  });
  console.log('Loading local automation page');
  await automationWindow.loadURL(`http://127.0.0.1:${address.port}/${pathToken}/runtime.html`);
  console.log('Local automation page loaded');
  const result = await automationWindow.webContents.executeJavaScript(`Promise.race([
    (async () => ({
      captcha: await globalThis.localAutomationRuntime.recognize(
        ${JSON.stringify(`data:image/jpeg;base64,${fixture}`)}
      ),
      totp: await globalThis.localAutomationRuntime.generateTotp(
        'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ',
        59000
      ),
      totpUri: await globalThis.localAutomationRuntime.generateTotp(
        'otpauth://totp/SMSMonitor?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ',
        59000
      )
    }))(),
    new Promise((_, reject) => setTimeout(() => reject(new Error('运行时初始化超过 30 秒')), 30000))
  ])`);
  assert.equal(result.captcha, 'nRVr');
  assert.equal(result.totp, '287082');
  assert.equal(result.totpUri, '287082');
  console.log('Local OCR and TOTP runtime checks passed');
} catch (error) {
  exitCode = 1;
  console.error(error?.stack || error);
} finally {
  clearTimeout(watchdog);
  if (automationWindow && !automationWindow.isDestroyed()) automationWindow.destroy();
  if (server.listening) server.close();
  app.exit(exitCode);
}
