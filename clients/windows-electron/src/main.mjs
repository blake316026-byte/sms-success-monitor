import {
  app,
  BrowserWindow,
  ipcMain,
  Menu,
  Notification,
  safeStorage,
  WebContentsView
} from 'electron';
import crypto from 'node:crypto';
import fs from 'node:fs';
import fsPromises from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  ALERT_THRESHOLD,
  calculateMetrics,
  isAlert,
  MAX_SAMPLE_LIMIT,
  MIN_SAMPLE_LIMIT,
  normalizeSampleLimit,
  percentageText,
  SAMPLE_LIMIT,
  SCAN_FAILURE_RELOAD_THRESHOLD,
  SCAN_INTERVAL_MS,
  shouldReloadAfterFailure,
  summarize
} from '../build/monitor-core.mjs';
import {
  DEFAULT_WORKBENCH_ZOOM_FACTOR,
  MAX_WORKBENCH_ZOOM_FACTOR,
  MIN_WORKBENCH_ZOOM_FACTOR,
  nextWorkbenchZoomFactor,
  normalizeWorkbenchZoomFactor
} from './workbench-zoom.mjs';

const currentDirectory = path.dirname(fileURLToPath(import.meta.url));
const clientRoot = path.resolve(currentDirectory, '..');
const sharedRoot = app.isPackaged
  ? path.join(process.resourcesPath, 'shared')
  : path.resolve(clientRoot, '../shared');
const modules = JSON.parse(fs.readFileSync(path.join(sharedRoot, 'modules.json'), 'utf8'));
const scanSource = fs.readFileSync(path.join(sharedRoot, 'scan.js'), 'utf8');
const loginAutomationSource = fs.readFileSync(
  path.join(sharedRoot, 'auto-login/login-page.js'),
  'utf8'
);
const shellHeight = 112;
const maximumAutoLoginAttempts = 5;
const autoLoginCooldownMs = 5 * 60_000;

const pages = new Map();
const moduleStates = new Map();
let workbenchWindow;
let widgetWindow;
let detailWindow;
let selectedPageId = modules[0].id;
let attachedView;
let quitting = false;
let customPagesPath;
let credentialsPath;
let settingsPath;
let credentialProfiles = {};
let sampleLimit = SAMPLE_LIMIT;
let workbenchZoomFactor = DEFAULT_WORKBENCH_ZOOM_FACTOR;
let localAutomationServer;
let localAutomationWindow;
let localAutomationReady;
let localAutomationError;
let scanTimer;

for (const module of modules) {
  moduleStates.set(module.id, {
    ...module,
    monitored: true,
    status: 'starting',
    message: '等待连接',
    metrics: null,
    scannedAt: null,
    nextScanAt: null,
    scanning: false,
    consecutiveScanFailures: 0,
    autoLoginAttempts: 0,
    autoLoginInProgress: false,
    autoLoginStage: '',
    autoLoginCooldownUntil: 0,
    autoLoginTimer: null,
    needsImmediateScan: true
  });
}

function contentType(filePath) {
  return {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.mjs': 'text/javascript; charset=utf-8',
    '.wasm': 'application/wasm',
    '.onnx': 'application/octet-stream',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.png': 'image/png'
  }[path.extname(filePath).toLowerCase()] || 'application/octet-stream';
}

async function startLocalAutomationRuntime() {
  const runtimeRoot = path.join(sharedRoot, 'auto-login');
  const pathToken = crypto.randomUUID();
  localAutomationServer = http.createServer((request, response) => {
    let requestPath = '';
    try {
      requestPath = decodeURIComponent(new URL(request.url, 'http://127.0.0.1').pathname);
    } catch (_) {
      response.writeHead(400).end();
      return;
    }
    const prefix = `/${pathToken}/`;
    if (request.method !== 'GET' || !requestPath.startsWith(prefix)) {
      response.writeHead(404).end();
      return;
    }
    const relativePath = requestPath.slice(prefix.length);
    const filePath = path.resolve(runtimeRoot, relativePath);
    if (!relativePath || !filePath.startsWith(`${runtimeRoot}${path.sep}`)) {
      response.writeHead(400).end();
      return;
    }
    const stream = fs.createReadStream(filePath);
    stream.once('error', () => {
      if (!response.headersSent) response.writeHead(404);
      response.end();
    });
    stream.once('open', () => {
      response.writeHead(200, {
        'Content-Type': contentType(filePath),
        'Cache-Control': 'no-store'
      });
      stream.pipe(response);
    });
  });
  await new Promise((resolve, reject) => {
    localAutomationServer.once('error', reject);
    localAutomationServer.listen(0, '127.0.0.1', resolve);
  });
  const address = localAutomationServer.address();
  const runtimeURL = `http://127.0.0.1:${address.port}/${pathToken}/runtime.html`;
  localAutomationWindow = new BrowserWindow({
    show: false,
    skipTaskbar: true,
    webPreferences: {
      backgroundThrottling: false,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  });
  localAutomationReady = localAutomationWindow.loadURL(runtimeURL)
    .then(() => localAutomationWindow.webContents.executeJavaScript(
      'globalThis.localAutomationRuntime.ready()'
    ))
    .then(() => true)
    .catch((error) => {
      localAutomationError = error;
      return false;
    });
}

async function callLocalAutomation(method, ...args) {
  if (!localAutomationReady || !localAutomationWindow || localAutomationWindow.isDestroyed()) {
    throw new Error('本地自动登录组件尚未就绪');
  }
  await localAutomationReady;
  if (localAutomationError) throw localAutomationError;
  return Promise.race([
    localAutomationWindow.webContents.executeJavaScript(
      `globalThis.localAutomationRuntime[${JSON.stringify(method)}](...${JSON.stringify(args)})`
    ),
    new Promise((_, reject) => setTimeout(
      () => reject(new Error('本地自动登录操作超过 45 秒')),
      45_000
    ))
  ]);
}

async function performPackagedLocalAutomationCheck() {
  if (!safeStorage.isEncryptionAvailable()) {
    throw new Error('Windows DPAPI safeStorage is unavailable');
  }
  const encrypted = safeStorage.encryptString('local-only');
  if (safeStorage.decryptString(encrypted) !== 'local-only') {
    throw new Error('Windows DPAPI safeStorage round trip failed');
  }
  if (
    nextWorkbenchZoomFactor(1, 'in') !== 1.1
    || nextWorkbenchZoomFactor(1, 'out') !== 0.9
    || nextWorkbenchZoomFactor(1.5, 'reset') !== 1
  ) {
    throw new Error('Windows workbench zoom runtime check failed');
  }
  const zoomCheckView = new WebContentsView({
    webPreferences: { contextIsolation: true, nodeIntegration: false, sandbox: true }
  });
  try {
    await zoomCheckView.webContents.loadURL('about:blank');
    zoomCheckView.webContents.setZoomFactor(1.25);
    if (Math.abs(zoomCheckView.webContents.getZoomFactor() - 1.25) > 0.001) {
      throw new Error('Windows WebContentsView zoom factor did not apply');
    }
  } finally {
    zoomCheckView.webContents.close();
  }

  await startLocalAutomationRuntime();
  const fixture = await fsPromises.readFile(
    path.join(sharedRoot, 'auto-login/fixtures/nRVr.jpg')
  );
  const captcha = await callLocalAutomation(
    'recognize',
    `data:image/jpeg;base64,${fixture.toString('base64')}`
  );
  const totp = await callLocalAutomation(
    'generateTotp',
    'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ',
    59_000
  );
  const totpUri = await callLocalAutomation(
    'generateTotp',
    'otpauth://totp/SMSMonitor?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ',
    59_000
  );
  if (captcha !== 'nRVr' || totp !== '287082' || totpUri !== '287082') {
    throw new Error('Packaged local OCR or TOTP self-test returned an unexpected result');
  }
}

async function runPackagedLocalAutomationCheck() {
  let timeout;
  try {
    await Promise.race([
      performPackagedLocalAutomationCheck(),
      new Promise((_, reject) => {
        timeout = setTimeout(
          () => reject(new Error('Packaged Windows local automation check exceeded 90 seconds')),
          90_000
        );
      })
    ]);
  } finally {
    clearTimeout(timeout);
  }
}

function profileFor(id) {
  const profile = credentialProfiles[id];
  return profile && typeof profile === 'object' ? profile : null;
}

function canAutoLogin(profile) {
  return Boolean(
    profile?.autoLoginEnabled
    && String(profile.username || '').trim()
    && String(profile.password || '')
  );
}

async function loadCredentialProfiles() {
  credentialsPath = path.join(app.getPath('userData'), 'local-login-profiles.json');
  try {
    if (!safeStorage.isEncryptionAvailable()) return;
    const envelope = JSON.parse(await fsPromises.readFile(credentialsPath, 'utf8'));
    const decrypted = safeStorage.decryptString(Buffer.from(envelope.payload, 'base64'));
    const stored = JSON.parse(decrypted);
    credentialProfiles = stored && typeof stored === 'object' ? stored : {};
  } catch (_) {
    credentialProfiles = {};
  }
}

async function saveCredentialProfiles() {
  if (!safeStorage.isEncryptionAvailable()) {
    throw new Error('Windows 本地安全存储当前不可用');
  }
  const encrypted = safeStorage.encryptString(JSON.stringify(credentialProfiles));
  await fsPromises.mkdir(path.dirname(credentialsPath), { recursive: true });
  await fsPromises.writeFile(
    credentialsPath,
    `${JSON.stringify({ version: 1, payload: encrypted.toString('base64') })}\n`,
    { mode: 0o600 }
  );
}

async function loadMonitorSettings() {
  settingsPath = path.join(app.getPath('userData'), 'monitor-settings.json');
  try {
    const stored = JSON.parse(await fsPromises.readFile(settingsPath, 'utf8'));
    sampleLimit = normalizeSampleLimit(stored?.sampleLimit);
    workbenchZoomFactor = normalizeWorkbenchZoomFactor(stored?.workbenchZoomFactor);
  } catch (_) {
    sampleLimit = SAMPLE_LIMIT;
    workbenchZoomFactor = DEFAULT_WORKBENCH_ZOOM_FACTOR;
  }
}

async function saveMonitorSettings() {
  await fsPromises.mkdir(path.dirname(settingsPath), { recursive: true });
  await fsPromises.writeFile(
    settingsPath,
    `${JSON.stringify({ version: 1, sampleLimit, workbenchZoomFactor }, null, 2)}\n`,
    { mode: 0o600 }
  );
}

async function updateStoredToken(id, token) {
  const profile = profileFor(id);
  const normalized = String(token || '').trim();
  if (!profile || !normalized || normalized === profile.token) return;
  profile.token = normalized;
  try {
    await saveCredentialProfiles();
  } catch (error) {
    console.error(`Unable to persist local token for ${id}: ${error.message}`);
  }
}

function uiPath(name) {
  return path.join(clientRoot, 'build', name);
}

function normalizeURL(value) {
  const trimmed = String(value || '').trim();
  if (!trimmed) return null;
  try {
    const url = new URL(trimmed.includes('://') ? trimmed : `https://${trimmed}`);
    return ['http:', 'https:'].includes(url.protocol) ? url.href : null;
  } catch (_) {
    return null;
  }
}

function isAuthenticationURL(value) {
  try {
    return ['/login', '/ga-auth', '/unlock-ip'].includes(new URL(value).pathname);
  } catch (_) {
    return false;
  }
}

function isConfiguredOrigin(module, value) {
  try {
    return new URL(module.url).origin === new URL(value).origin;
  } catch (_) {
    return false;
  }
}

function applyWorkbenchZoom() {
  for (const page of pages.values()) {
    if (!page.view.webContents.isDestroyed()) {
      page.view.webContents.setZoomFactor(workbenchZoomFactor);
    }
  }
}

async function changeWorkbenchZoom(direction) {
  const nextFactor = nextWorkbenchZoomFactor(workbenchZoomFactor, direction);
  if (nextFactor === workbenchZoomFactor) {
    return { ok: true, zoomPercent: Math.round(workbenchZoomFactor * 100) };
  }

  const previousFactor = workbenchZoomFactor;
  workbenchZoomFactor = nextFactor;
  applyWorkbenchZoom();
  broadcastSnapshot();
  try {
    await saveMonitorSettings();
  } catch (error) {
    workbenchZoomFactor = previousFactor;
    applyWorkbenchZoom();
    broadcastSnapshot();
    return { ok: false, message: `无法保存缩放设置：${error.message}` };
  }
  return { ok: true, zoomPercent: Math.round(workbenchZoomFactor * 100) };
}

function createRemotePage(page) {
  const view = new WebContentsView({
    webPreferences: {
      partition: `persist:sms-monitor-${page.id}`,
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: true,
      spellcheck: false
    }
  });
  view.setBackgroundColor('#ffffff');
  view.webContents.session.setPermissionRequestHandler((_contents, _permission, callback) => {
    callback(false);
  });
  view.webContents.setWindowOpenHandler(({ url }) => {
    view.webContents.loadURL(url);
    return { action: 'deny' };
  });
  view.webContents.on('did-finish-load', () => {
    view.webContents.setZoomFactor(workbenchZoomFactor);
    handlePageFinished(page.id);
  });
  view.webContents.on('did-navigate', () => broadcastSnapshot());
  view.webContents.on('did-navigate-in-page', () => broadcastSnapshot());
  view.webContents.on('zoom-changed', (_event, direction) => {
    void changeWorkbenchZoom(direction);
  });
  view.webContents.on('render-process-gone', () => {
    if (quitting || !page.monitored) return;
    updateModule(page.id, {
      status: 'error',
      message: '平台页面进程已重启，正在恢复。',
      scanning: false,
      consecutiveScanFailures: 0,
      needsImmediateScan: true,
      autoLoginInProgress: false,
      autoLoginStage: '',
      scannedAt: Date.now(),
      nextScanAt: Date.now() + SCAN_INTERVAL_MS
    });
    setTimeout(() => {
      if (!view.webContents.isDestroyed()) view.webContents.reload();
    }, 500);
  });
  view.webContents.on('did-fail-load', (_event, code, description, validatedURL, isMainFrame) => {
    if (!isMainFrame || code === -3 || !page.monitored) return;
    const recovering = handleScanFailure(page.id, `页面加载失败：${description}`);
    if (!recovering && !validatedURL) view.webContents.loadURL(page.url);
  });
  pages.set(page.id, { ...page, view });
  view.webContents.loadURL(page.url);
  return view;
}

async function handlePageFinished(id) {
  const page = pages.get(id);
  if (!page || !page.monitored) {
    broadcastSnapshot();
    return;
  }
  const state = moduleStates.get(id);
  const currentURL = page.view.webContents.getURL();
  if (isAuthenticationURL(currentURL)) {
    handleAuthenticationRequired(id, '平台需要重新登录。');
    return;
  }
  if (!isConfiguredOrigin(state, currentURL)) return;
  resetAutoLoginState(state);
  persistCurrentToken(id);
  if (!state.needsImmediateScan) {
    broadcastSnapshot();
    return;
  }
  state.needsImmediateScan = false;
  setTimeout(() => scanModule(id), 900);
}

function updateModule(id, changes, changedId = id) {
  const state = moduleStates.get(id);
  if (!state) return;
  Object.assign(state, changes);
  broadcastSnapshot(changedId);
}

function loginURLFor(state) {
  const url = new URL(state.url);
  url.pathname = '/login';
  url.search = '';
  return url.href;
}

function timeText(timestamp) {
  return new Date(timestamp).toLocaleTimeString('zh-CN', { hour12: false });
}

async function runLoginPageAction(page, expression) {
  return page.view.webContents.executeJavaScript(
    `(async () => { ${loginAutomationSource}\nreturn await (${expression}); })()`
  );
}

async function persistCurrentToken(id) {
  const page = pages.get(id);
  const state = moduleStates.get(id);
  if (!page || !state || !profileFor(id)) return;
  let token = '';
  try {
    token = await runLoginPageAction(
      page,
      'globalThis.smsLoginAutomation.extractToken()'
    );
  } catch (_) {
    // The site WebView remains the primary local token store.
  }
  if (!token) {
    try {
      const cookies = await page.view.webContents.session.cookies.get({ url: state.url });
      token = cookies.find((cookie) => (
        cookie.name.toLowerCase() === 'token' && String(cookie.value || '').length > 12
      ))?.value || '';
    } catch (_) {
      // Token persistence is best effort and never interrupts monitoring.
    }
  }
  await updateStoredToken(id, token);
}

function resetAutoLoginState(state) {
  state.autoLoginAttempts = 0;
  state.autoLoginInProgress = false;
  state.autoLoginStage = '';
  state.autoLoginCooldownUntil = 0;
  if (state.autoLoginTimer) clearTimeout(state.autoLoginTimer);
  state.autoLoginTimer = null;
}

function pauseAutoLogin(id, detail = '') {
  const state = moduleStates.get(id);
  if (!state) return;
  state.autoLoginInProgress = false;
  state.autoLoginStage = '';
  state.autoLoginCooldownUntil = Date.now() + autoLoginCooldownMs;
  const suffix = detail ? `（${detail}）` : '';
  updateModule(id, {
    status: 'auth',
    message: `自动登录已连续失败 ${maximumAutoLoginAttempts} 次${suffix}，暂停至 ${timeText(state.autoLoginCooldownUntil)}。`,
    metrics: null,
    nextScanAt: Date.now() + SCAN_INTERVAL_MS
  });
}

function retryAutoLogin(id, message) {
  const state = moduleStates.get(id);
  const page = pages.get(id);
  if (!state || !page) return;
  state.autoLoginInProgress = false;
  state.autoLoginStage = '';
  state.autoLoginAttempts += 1;
  if (state.autoLoginAttempts >= maximumAutoLoginAttempts) {
    pauseAutoLogin(id, message);
    return;
  }
  updateModule(id, {
    status: 'starting',
    message: `${message}，稍后自动重试`,
    nextScanAt: Date.now() + SCAN_INTERVAL_MS
  });
  state.autoLoginTimer = setTimeout(() => {
    const currentURL = page.view.webContents.getURL();
    attemptAutoLogin(id, currentURL);
  }, 1500);
}

async function completeAutoLogin(id, token = '') {
  const state = moduleStates.get(id);
  const page = pages.get(id);
  if (!state || !page) return;
  resetAutoLoginState(state);
  state.needsImmediateScan = true;
  if (token) await updateStoredToken(id, token);
  await persistCurrentToken(id);
  updateModule(id, {
    status: 'starting',
    message: '自动登录成功，正在恢复监控',
    nextScanAt: Date.now() + SCAN_INTERVAL_MS
  });
  const currentURL = page.view.webContents.getURL();
  if (!isConfiguredOrigin(state, currentURL)) {
    page.view.webContents.loadURL(state.url);
    return;
  }
  setTimeout(() => scanModule(id), 900);
}

function scheduleAutoLoginOutcomeCheck(id) {
  const state = moduleStates.get(id);
  const page = pages.get(id);
  if (!state || !page) return;
  if (state.autoLoginTimer) clearTimeout(state.autoLoginTimer);
  state.autoLoginTimer = setTimeout(async () => {
    state.autoLoginInProgress = false;
    const currentURL = page.view.webContents.getURL();
    if (isAuthenticationURL(currentURL)) {
      if (new URL(currentURL).pathname === '/ga-auth' && state.autoLoginStage !== 'totp') {
        state.autoLoginStage = '';
        attemptAutoLogin(id, currentURL);
      } else if (new URL(currentURL).pathname === '/ga-auth') {
        retryAutoLogin(id, 'Google 验证未通过，正在尝试备用时间窗口');
      } else {
        try {
          await runLoginPageAction(page, 'globalThis.smsLoginAutomation.refreshCaptcha()');
        } catch (_) {
          // A subsequent attempt will wait for the next captcha image.
        }
        retryAutoLogin(id, '登录尚未通过，正在更换验证码重试');
      }
      return;
    }
    completeAutoLogin(id);
  }, 7000);
}

async function attemptAutoLogin(id, currentURL) {
  const state = moduleStates.get(id);
  const page = pages.get(id);
  const profile = profileFor(id);
  if (!state || !page || state.autoLoginInProgress || !canAutoLogin(profile)) return;

  if (state.autoLoginCooldownUntil && state.autoLoginCooldownUntil <= Date.now()) {
    state.autoLoginAttempts = 0;
    state.autoLoginCooldownUntil = 0;
  }
  if (state.autoLoginCooldownUntil > Date.now()) {
    updateModule(id, {
      status: 'auth',
      message: `自动登录连续失败，已暂停至 ${timeText(state.autoLoginCooldownUntil)}。`,
      metrics: null
    });
    return;
  }
  if (state.autoLoginAttempts >= maximumAutoLoginAttempts) {
    pauseAutoLogin(id);
    return;
  }

  let pathName = '';
  try { pathName = new URL(currentURL).pathname; } catch (_) {}
  if (pathName === '/unlock-ip') {
    updateModule(id, {
      status: 'auth',
      message: '平台要求人工完成 IP 解锁，自动登录已暂停。',
      metrics: null
    });
    return;
  }

  state.autoLoginInProgress = true;
  updateModule(id, {
    status: 'starting',
    message: `正在自动登录（${state.autoLoginAttempts + 1}/${maximumAutoLoginAttempts}）`,
    metrics: null,
    nextScanAt: Date.now() + SCAN_INTERVAL_MS
  });

  try {
    const snapshot = await runLoginPageAction(
      page,
      'globalThis.smsLoginAutomation.snapshot()'
    );
    if (snapshot?.token) await updateStoredToken(id, snapshot.token);
    if (snapshot?.kind === 'login') {
      if (!snapshot.captchaDataUrl) {
        retryAutoLogin(id, '验证码图片尚未加载');
        return;
      }
      const captcha = await callLocalAutomation('recognize', snapshot.captchaDataUrl);
      if (!/^[0-9A-Za-z]{4,8}$/.test(String(captcha || ''))) {
        await runLoginPageAction(page, 'globalThis.smsLoginAutomation.refreshCaptcha()');
        retryAutoLogin(id, '本地验证码识别结果无效');
        return;
      }
      const submitted = await runLoginPageAction(
        page,
        `globalThis.smsLoginAutomation.submitLogin(${JSON.stringify({
          username: profile.username,
          password: profile.password,
          captcha
        })})`
      );
      if (!submitted?.submitted) {
        retryAutoLogin(id, submitted?.message || '登录表单尚未准备完成');
        return;
      }
      state.autoLoginStage = 'login';
      scheduleAutoLoginOutcomeCheck(id);
      return;
    }
    if (snapshot?.kind === 'totp') {
      const secret = String(profile.totpSecret || '').trim();
      if (!secret) {
        state.autoLoginInProgress = false;
        updateModule(id, {
          status: 'auth',
          message: '账号密码已通过，但本地未配置 Google 密钥，请人工完成二次验证。',
          metrics: null
        });
        return;
      }
      const offsets = [0, -210, 210, -180, 180];
      const offset = offsets[Math.min(state.autoLoginAttempts, offsets.length - 1)];
      const cyclePosition = Math.floor((Date.now() / 1000 + offset) % 30);
      if (cyclePosition > 24) {
        await new Promise((resolve) => setTimeout(resolve, 6500));
        if (!state.autoLoginInProgress) return;
      }
      const code = await callLocalAutomation('generateTotp', secret, Date.now() + offset * 1000);
      const submitted = await runLoginPageAction(
        page,
        `globalThis.smsLoginAutomation.submitTotp(${JSON.stringify({ code })})`
      );
      if (!submitted?.submitted) {
        retryAutoLogin(id, submitted?.message || 'Google 验证页面尚未准备完成');
        return;
      }
      state.autoLoginStage = 'totp';
      scheduleAutoLoginOutcomeCheck(id);
      return;
    }
    if (snapshot?.kind === 'authenticated') {
      await completeAutoLogin(id, snapshot.token || '');
      return;
    }
    state.autoLoginInProgress = false;
    updateModule(id, {
      status: 'auth',
      message: '平台要求人工完成 IP 解锁，自动登录已暂停。',
      metrics: null
    });
  } catch (error) {
    retryAutoLogin(id, `自动登录失败：${error.message}`);
  }
}

function handleAuthenticationRequired(id, message) {
  const state = moduleStates.get(id);
  const page = pages.get(id);
  if (!state || !page) return;
  state.scanning = false;
  state.consecutiveScanFailures = 0;
  state.needsImmediateScan = true;
  state.nextScanAt = Date.now() + SCAN_INTERVAL_MS;
  const profile = profileFor(id);
  if (!canAutoLogin(profile)) {
    updateModule(id, {
      status: 'auth',
      message: `${message} 请打开对应后台标签完成登录。`,
      metrics: null
    });
    return;
  }
  updateModule(id, {
    status: 'starting',
    message: 'Token 已失效，正在自动登录',
    metrics: null
  });
  const currentURL = page.view.webContents.getURL();
  if (isAuthenticationURL(currentURL)) attemptAutoLogin(id, currentURL);
  else page.view.webContents.loadURL(loginURLFor(state));
}

function handleScanFailure(id, message) {
  const state = moduleStates.get(id);
  const page = pages.get(id);
  if (!state || !page) return false;

  state.scanning = false;
  state.consecutiveScanFailures += 1;
  state.status = 'error';
  state.message = message;
  state.scannedAt = Date.now();
  state.nextScanAt = Date.now() + SCAN_INTERVAL_MS;

  if (shouldReloadAfterFailure(
    state.consecutiveScanFailures,
    SCAN_FAILURE_RELOAD_THRESHOLD
  )) {
    state.consecutiveScanFailures = 0;
    state.needsImmediateScan = true;
    state.message = `${message}；正在自动重载后台连接。`;
    page.view.webContents.reload();
    broadcastSnapshot(id);
    return true;
  }
  broadcastSnapshot(id);
  return false;
}

async function scanModule(id) {
  const state = moduleStates.get(id);
  const page = pages.get(id);
  if (!state || !page || state.scanning) return;
  const currentURL = page.view.webContents.getURL();
  if (!currentURL) return;
  if (isAuthenticationURL(currentURL)) {
    handleAuthenticationRequired(id, '平台登录已失效。');
    return;
  }
  if (!isConfiguredOrigin(state, currentURL)) {
    page.view.webContents.loadURL(state.url);
    updateModule(id, {
      status: 'starting',
      message: '正在返回后台入口',
      nextScanAt: Date.now() + 10_000
    });
    return;
  }

  state.scanning = true;
  const activeSampleLimit = sampleLimit;
  state.status = 'scanning';
  state.message = `正在读取最新 ${activeSampleLimit} 条`;
  state.nextScanAt = Date.now() + SCAN_INTERVAL_MS;
  broadcastSnapshot(id);

  try {
    const result = await page.view.webContents.executeJavaScript(
      `(async () => { ${scanSource}\nreturn await globalThis.smsMonitorScan(${activeSampleLimit}); })()`,
      true
    );
    state.scanning = false;
    if (activeSampleLimit !== sampleLimit) {
      state.needsImmediateScan = false;
      setTimeout(() => scanModule(id), 0);
      return;
    }
    if (!result || typeof result !== 'object') {
      throw new Error('扫描结果无法识别');
    }
    if (result.kind === 'auth') {
      handleAuthenticationRequired(id, result.message || '平台登录已失效。');
      return;
    } else if (result.kind === 'ok') {
      const metrics = calculateMetrics(result.statuses, activeSampleLimit);
      if (metrics.sampleCount === 0) throw new Error('短信记录接口未返回可统计记录');
      Object.assign(state, {
        status: isAlert(metrics, ALERT_THRESHOLD) ? 'alert' : 'healthy',
        message: isAlert(metrics, ALERT_THRESHOLD) ? '成功率低于 50%' : '成功率正常',
        metrics,
        consecutiveScanFailures: 0,
        scannedAt: Date.now(),
        nextScanAt: Date.now() + SCAN_INTERVAL_MS
      });
    } else {
      handleScanFailure(id, result.message || '短信记录接口扫描失败');
      return;
    }
  } catch (error) {
    if (activeSampleLimit !== sampleLimit) {
      state.scanning = false;
      state.needsImmediateScan = false;
      setTimeout(() => scanModule(id), 0);
      return;
    }
    handleScanFailure(id, `扫描失败：${error.message}`);
    return;
  }
  broadcastSnapshot(id);
  maybeNotify(id);
}

function pageSnapshot(page) {
  const state = moduleStates.get(page.id);
  const history = page.view.webContents.navigationHistory;
  return {
    id: page.id,
    name: page.name,
    url: page.url,
    currentURL: page.view.webContents.getURL() || page.url,
    monitored: page.monitored,
    status: state?.status || 'page',
    canGoBack: history.canGoBack(),
    canGoForward: history.canGoForward(),
    loading: page.view.webContents.isLoading()
  };
}

function buildSnapshot() {
  const moduleList = modules.map((module) => {
    const state = moduleStates.get(module.id);
    return {
      id: state.id,
      name: state.name,
      url: state.url,
      status: state.status,
      message: state.message,
      metrics: state.metrics,
      scannedAt: state.scannedAt,
      nextScanAt: state.nextScanAt,
      alertThreshold: ALERT_THRESHOLD,
      percentageText: percentageText(state.metrics)
    };
  });
  const summary = summarize(moduleList);
  return {
    modules: moduleList,
    pages: [...pages.values()].map(pageSnapshot),
    selectedPageId,
    sampleLimit,
    minimumSampleLimit: MIN_SAMPLE_LIMIT,
    maximumSampleLimit: MAX_SAMPLE_LIMIT,
    workbenchZoomPercent: Math.round(workbenchZoomFactor * 100),
    minimumWorkbenchZoomPercent: Math.round(MIN_WORKBENCH_ZOOM_FACTOR * 100),
    maximumWorkbenchZoomPercent: Math.round(MAX_WORKBENCH_ZOOM_FACTOR * 100),
    summary: {
      alertCount: summary.alertCount,
      healthyCount: summary.healthyCount,
      authenticationCount: summary.authenticationCount,
      errorCount: summary.errorCount,
      focusId: summary.focus?.id || null
    }
  };
}

function broadcastSnapshot() {
  const snapshot = buildSnapshot();
  for (const window of [workbenchWindow, widgetWindow, detailWindow]) {
    if (window && !window.isDestroyed()) {
      window.webContents.send('snapshot:changed', snapshot);
    }
  }
}

function maybeNotify(changedId) {
  const snapshot = buildSnapshot();
  const focus = snapshot.modules.find((module) => module.id === snapshot.summary.focusId);
  if (!focus || focus.id !== changedId || focus.status !== 'alert') return;
  new Notification({
    title: `${focus.name} 短信成功率报警`,
    body: `最新 ${focus.metrics.sampleCount} 条成功 ${focus.metrics.successCount} 条，成功率 ${focus.percentageText}，低于 50%。`,
    urgency: 'critical'
  }).show();
  widgetWindow?.flashFrame(true);
}

function attachSelectedView() {
  if (!workbenchWindow || workbenchWindow.isDestroyed()) return;
  const selected = pages.get(selectedPageId) || pages.values().next().value;
  if (!selected) return;
  selectedPageId = selected.id;
  if (attachedView && attachedView !== selected.view) {
    workbenchWindow.contentView.removeChildView(attachedView);
  }
  if (attachedView !== selected.view) {
    workbenchWindow.contentView.addChildView(selected.view);
    attachedView = selected.view;
  }
  layoutSelectedView();
  broadcastSnapshot();
}

function layoutSelectedView() {
  if (!workbenchWindow || !attachedView) return;
  const bounds = workbenchWindow.getContentBounds();
  attachedView.setBounds({
    x: 0,
    y: shellHeight,
    width: Math.max(1, bounds.width),
    height: Math.max(1, bounds.height - shellHeight)
  });
}

function createWorkbenchWindow() {
  workbenchWindow = new BrowserWindow({
    width: 1260,
    height: 800,
    minWidth: 940,
    minHeight: 620,
    title: '短信后台工作台',
    backgroundColor: '#ffffff',
    webPreferences: {
      preload: path.join(currentDirectory, 'preload.cjs'),
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: true
    }
  });
  workbenchWindow.loadFile(uiPath('workbench.html'));
  workbenchWindow.on('resize', layoutSelectedView);
  workbenchWindow.on('close', (event) => {
    if (quitting) return;
    event.preventDefault();
    workbenchWindow.hide();
  });
  workbenchWindow.webContents.on('did-finish-load', () => {
    attachSelectedView();
    broadcastSnapshot();
  });
}

function createWidgetWindow() {
  widgetWindow = new BrowserWindow({
    width: 228,
    height: 236,
    frame: false,
    transparent: true,
    resizable: false,
    alwaysOnTop: true,
    skipTaskbar: false,
    show: false,
    backgroundColor: '#00000000',
    webPreferences: {
      preload: path.join(currentDirectory, 'preload.cjs'),
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: true
    }
  });
  widgetWindow.setAlwaysOnTop(true, 'screen-saver');
  widgetWindow.loadFile(uiPath('widget.html'));
  widgetWindow.once('ready-to-show', () => {
    widgetWindow.showInactive();
    broadcastSnapshot();
  });
  widgetWindow.on('close', (event) => {
    if (quitting) return;
    event.preventDefault();
  });
}

function createDetailWindow() {
  detailWindow = new BrowserWindow({
    width: 780,
    height: 540,
    minWidth: 700,
    minHeight: 440,
    title: '短信监控总览',
    show: false,
    backgroundColor: '#ffffff',
    webPreferences: {
      preload: path.join(currentDirectory, 'preload.cjs'),
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: true
    }
  });
  detailWindow.loadFile(uiPath('detail.html'));
  detailWindow.on('close', (event) => {
    if (quitting) return;
    event.preventDefault();
    detailWindow.hide();
  });
}

function createApplicationMenu() {
  const menu = Menu.buildFromTemplate([
    {
      label: '文件',
      submenu: [
        { label: '打开后台工作台', click: () => showWorkbench() },
        { label: '监控总览', click: () => showDetail() },
        { type: 'separator' },
        { role: 'quit', label: '退出' }
      ]
    },
    {
      label: '编辑',
      submenu: [
        { role: 'undo', label: '撤销' },
        { role: 'redo', label: '重做' },
        { type: 'separator' },
        { role: 'cut', label: '剪切' },
        { role: 'copy', label: '复制' },
        { role: 'paste', label: '粘贴' },
        { role: 'selectAll', label: '全选' }
      ]
    },
    {
      label: '查看',
      submenu: [
        {
          label: '放大后台页面',
          accelerator: 'CmdOrCtrl+=',
          click: () => { void changeWorkbenchZoom('in'); }
        },
        {
          label: '缩小后台页面',
          accelerator: 'CmdOrCtrl+-',
          click: () => { void changeWorkbenchZoom('out'); }
        },
        {
          label: '恢复实际大小',
          accelerator: 'CmdOrCtrl+0',
          click: () => { void changeWorkbenchZoom('reset'); }
        }
      ]
    },
    {
      label: '窗口',
      submenu: [
        { role: 'minimize', label: '最小化' },
        { role: 'zoom', label: '缩放' },
        { type: 'separator' },
        { role: 'front', label: '前置所有窗口' }
      ]
    }
  ]);
  Menu.setApplicationMenu(menu);
}

function showWorkbench(id) {
  if (id && pages.has(id)) selectedPageId = id;
  attachSelectedView();
  workbenchWindow.show();
  workbenchWindow.focus();
}

function showDetail() {
  detailWindow.show();
  detailWindow.focus();
  broadcastSnapshot();
}

async function loadCustomPages() {
  customPagesPath = path.join(app.getPath('userData'), 'custom-pages.json');
  try {
    const stored = JSON.parse(await fsPromises.readFile(customPagesPath, 'utf8'));
    return Array.isArray(stored) ? stored : [];
  } catch (_) {
    return [];
  }
}

async function saveCustomPages() {
  const custom = [...pages.values()]
    .filter((page) => !page.monitored)
    .map(({ id, name, url }) => ({ id, name, url, monitored: false }));
  await fsPromises.mkdir(path.dirname(customPagesPath), { recursive: true });
  await fsPromises.writeFile(customPagesPath, `${JSON.stringify(custom, null, 2)}\n`);
}

function credentialSummary(id) {
  const profile = profileFor(id);
  return {
    configured: Boolean(profile),
    username: String(profile?.username || ''),
    passwordConfigured: Boolean(profile?.password),
    totpConfigured: Boolean(profile?.totpSecret),
    tokenConfigured: Boolean(profile?.token),
    autoLoginEnabled: Boolean(profile?.autoLoginEnabled)
  };
}

function restartAutoLoginFor(id) {
  const state = moduleStates.get(id);
  const page = pages.get(id);
  if (!state || !page) return;
  resetAutoLoginState(state);
  persistCurrentToken(id);
  const currentURL = page.view.webContents.getURL();
  if (isAuthenticationURL(currentURL)) {
    handleAuthenticationRequired(id, '自动登录配置已更新。');
  }
}

function registerIPC() {
  ipcMain.handle('snapshot:get', () => buildSnapshot());
  ipcMain.handle('page:select', (_event, id) => {
    if (!pages.has(id)) return false;
    selectedPageId = id;
    attachSelectedView();
    return true;
  });
  ipcMain.handle('page:navigate', (_event, value) => {
    const url = normalizeURL(value);
    const page = pages.get(selectedPageId);
    if (!url || !page) return false;
    page.view.webContents.loadURL(url);
    if (!page.monitored) {
      page.url = url;
      saveCustomPages();
    }
    return true;
  });
  ipcMain.handle('page:back', () => {
    const history = pages.get(selectedPageId)?.view.webContents.navigationHistory;
    if (history?.canGoBack()) history.goBack();
  });
  ipcMain.handle('page:forward', () => {
    const history = pages.get(selectedPageId)?.view.webContents.navigationHistory;
    if (history?.canGoForward()) history.goForward();
  });
  ipcMain.handle('page:reload', () => pages.get(selectedPageId)?.view.webContents.reload());
  ipcMain.handle('page:add', async (_event, input) => {
    const url = normalizeURL(input?.url);
    const name = String(input?.name || '').trim();
    if (!url || !name) return { ok: false, message: '页面名称或地址无效' };
    const page = { id: `custom-${crypto.randomUUID()}`, name, url, monitored: false };
    createRemotePage(page);
    await saveCustomPages();
    selectedPageId = page.id;
    attachSelectedView();
    return { ok: true, id: page.id };
  });
  ipcMain.handle('page:close', async (_event, id) => {
    const page = pages.get(id);
    if (!page || page.monitored) return false;
    if (attachedView === page.view) {
      workbenchWindow.contentView.removeChildView(page.view);
      attachedView = null;
    }
    pages.delete(id);
    await page.view.webContents.session.clearStorageData();
    page.view.webContents.close();
    selectedPageId = modules[0].id;
    await saveCustomPages();
    attachSelectedView();
    return true;
  });
  ipcMain.handle('monitor:scan', (_event, id) => {
    if (id) scanModule(id);
    else modules.forEach((module) => scanModule(module.id));
  });
  ipcMain.handle('settings:set-sample-limit', async (_event, value) => {
    const parsed = Math.round(Number(value));
    if (!Number.isFinite(parsed) || parsed < MIN_SAMPLE_LIMIT || parsed > MAX_SAMPLE_LIMIT) {
      return {
        ok: false,
        message: `样本条数必须在 ${MIN_SAMPLE_LIMIT}–${MAX_SAMPLE_LIMIT} 之间`
      };
    }
    if (parsed === sampleLimit) return { ok: true, sampleLimit };
    sampleLimit = parsed;
    try {
      await saveMonitorSettings();
    } catch (error) {
      return { ok: false, message: `无法保存本地设置：${error.message}` };
    }
    for (const state of moduleStates.values()) {
      state.metrics = null;
      state.needsImmediateScan = true;
      state.status = state.scanning ? 'scanning' : 'starting';
      state.message = `样本已改为 ${sampleLimit} 条，正在重新扫描`;
    }
    broadcastSnapshot();
    modules.forEach((module) => scanModule(module.id));
    return { ok: true, sampleLimit };
  });
  ipcMain.handle('workbench:zoom', (_event, direction) => {
    if (!['in', 'out', 'reset'].includes(direction)) {
      return { ok: false, message: '无法识别缩放操作' };
    }
    return changeWorkbenchZoom(direction);
  });
  ipcMain.handle('credentials:get', (_event, id) => {
    const page = pages.get(id);
    if (!page?.monitored) return { ok: false, message: '当前页面不支持自动登录配置' };
    return { ok: true, profile: credentialSummary(id) };
  });
  ipcMain.handle('credentials:save', async (_event, id, input) => {
    const page = pages.get(id);
    if (!page?.monitored) return { ok: false, message: '当前页面不支持自动登录配置' };
    const existing = profileFor(id) || {};
    const username = String(input?.username || '').trim();
    const passwordInput = String(input?.password || '');
    const password = passwordInput || String(existing.password || '');
    if (!username || !password) return { ok: false, message: '账号和密码不能为空' };
    const totpSecret = input?.clearTotp
      ? ''
      : String(input?.totpSecret || '').trim() || String(existing.totpSecret || '');
    credentialProfiles[id] = {
      username,
      password,
      totpSecret,
      token: String(existing.token || ''),
      autoLoginEnabled: Boolean(input?.autoLoginEnabled)
    };
    try {
      await saveCredentialProfiles();
      restartAutoLoginFor(id);
      return { ok: true, profile: credentialSummary(id) };
    } catch (error) {
      return { ok: false, message: error.message };
    }
  });
  ipcMain.handle('credentials:remove', async (_event, id) => {
    const page = pages.get(id);
    if (!page?.monitored) return { ok: false, message: '当前页面不支持自动登录配置' };
    delete credentialProfiles[id];
    try {
      await saveCredentialProfiles();
      restartAutoLoginFor(id);
      return { ok: true };
    } catch (error) {
      return { ok: false, message: error.message };
    }
  });
  ipcMain.handle('window:workbench', (_event, id) => showWorkbench(id));
  ipcMain.handle('window:detail', () => showDetail());
  ipcMain.handle('app:quit', () => {
    quitting = true;
    app.quit();
  });
  ipcMain.handle('widget:menu', () => {
    Menu.buildFromTemplate([
      { label: '立即扫描全部后台', click: () => modules.forEach((module) => scanModule(module.id)) },
      { label: '监控总览', click: () => showDetail() },
      { label: '打开后台工作台', click: () => showWorkbench() },
      { type: 'separator' },
      { label: '退出', click: () => { quitting = true; app.quit(); } }
    ]).popup({ window: widgetWindow });
  });
}

app.whenReady().then(async () => {
  app.setAppUserModelId('com.local.sms-success-monitor');
  if (process.env.SMS_MONITOR_LOCAL_AUTOMATION_CHECK === '1') {
    const resultPath = process.env.SMS_MONITOR_LOCAL_AUTOMATION_RESULT || '';
    let exitCode = 0;
    let message = 'PASS: packaged Windows DPAPI, OCR, TOTP and workbench zoom checks passed';
    try {
      await runPackagedLocalAutomationCheck();
    } catch (error) {
      exitCode = 1;
      message = `FAIL: ${error.message}`;
    }
    if (resultPath) {
      try { await fsPromises.writeFile(resultPath, `${message}\n`, 'utf8'); } catch (_) {}
    }
    localAutomationWindow?.destroy();
    localAutomationServer?.close();
    app.exit(exitCode);
    return;
  }
  if (process.platform === 'win32' && app.isPackaged) {
    app.setLoginItemSettings({ openAtLogin: true, path: process.execPath });
  }
  await loadCredentialProfiles();
  await loadMonitorSettings();
  try {
    await startLocalAutomationRuntime();
  } catch (error) {
    console.error(`Local automation runtime failed to start: ${error.message}`);
  }
  createApplicationMenu();
  registerIPC();
  for (const module of modules) createRemotePage({ ...module, monitored: true });
  for (const page of await loadCustomPages()) createRemotePage(page);
  createWorkbenchWindow();
  createWidgetWindow();
  createDetailWindow();
  scanTimer = setInterval(() => {
    modules.forEach((module) => scanModule(module.id));
  }, SCAN_INTERVAL_MS);
});

app.on('before-quit', () => {
  quitting = true;
  if (scanTimer) clearInterval(scanTimer);
  for (const state of moduleStates.values()) {
    if (state.autoLoginTimer) clearTimeout(state.autoLoginTimer);
  }
  localAutomationWindow?.destroy();
  localAutomationServer?.close();
});

app.on('window-all-closed', () => {});

app.on('activate', () => showWorkbench());
