import {
  app,
  BrowserWindow,
  ipcMain,
  Menu,
  Notification,
  WebContentsView
} from 'electron';
import crypto from 'node:crypto';
import fs from 'node:fs';
import fsPromises from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  ALERT_THRESHOLD,
  calculateMetrics,
  isAlert,
  percentageText,
  SAMPLE_LIMIT,
  SCAN_FAILURE_RELOAD_THRESHOLD,
  SCAN_INTERVAL_MS,
  shouldReloadAfterFailure,
  summarize
} from '../build/monitor-core.mjs';

const currentDirectory = path.dirname(fileURLToPath(import.meta.url));
const clientRoot = path.resolve(currentDirectory, '..');
const sharedRoot = app.isPackaged
  ? path.join(process.resourcesPath, 'shared')
  : path.resolve(clientRoot, '../shared');
const modules = JSON.parse(fs.readFileSync(path.join(sharedRoot, 'modules.json'), 'utf8'));
const scanSource = fs.readFileSync(path.join(sharedRoot, 'scan.js'), 'utf8');
const shellHeight = 112;

const pages = new Map();
const moduleStates = new Map();
let workbenchWindow;
let widgetWindow;
let detailWindow;
let selectedPageId = modules[0].id;
let attachedView;
let quitting = false;
let customPagesPath;
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
    needsImmediateScan: true
  });
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
  view.webContents.on('did-finish-load', () => handlePageFinished(page.id));
  view.webContents.on('did-navigate', () => broadcastSnapshot());
  view.webContents.on('did-navigate-in-page', () => broadcastSnapshot());
  view.webContents.on('render-process-gone', () => {
    if (quitting || !page.monitored) return;
    updateModule(page.id, {
      status: 'error',
      message: '平台页面进程已重启，正在恢复。',
      scanning: false,
      consecutiveScanFailures: 0,
      needsImmediateScan: true,
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
    updateModule(id, {
      status: 'auth',
      message: '请完成平台登录',
      metrics: null,
      consecutiveScanFailures: 0,
      needsImmediateScan: true,
      nextScanAt: Date.now() + SCAN_INTERVAL_MS
    });
    return;
  }
  if (!isConfiguredOrigin(state, currentURL)) return;
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
    updateModule(id, {
      status: 'auth',
      message: '请完成平台登录',
      metrics: null,
      consecutiveScanFailures: 0,
      needsImmediateScan: true,
      nextScanAt: Date.now() + SCAN_INTERVAL_MS
    });
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
  state.status = 'scanning';
  state.message = '正在读取最新 200 条';
  state.nextScanAt = Date.now() + SCAN_INTERVAL_MS;
  broadcastSnapshot(id);

  try {
    const result = await page.view.webContents.executeJavaScript(
      `(async () => { ${scanSource}\nreturn await globalThis.smsMonitorScan(${SAMPLE_LIMIT}); })()`,
      true
    );
    state.scanning = false;
    if (!result || typeof result !== 'object') {
      throw new Error('扫描结果无法识别');
    }
    if (result.kind === 'auth') {
      Object.assign(state, {
        status: 'auth',
        message: result.message || '平台登录已失效',
        metrics: null,
        consecutiveScanFailures: 0,
        needsImmediateScan: true
      });
    } else if (result.kind === 'ok') {
      const metrics = calculateMetrics(result.statuses, SAMPLE_LIMIT);
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
  if (process.platform === 'win32' && app.isPackaged) {
    app.setLoginItemSettings({ openAtLogin: true, path: process.execPath });
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
});

app.on('window-all-closed', () => {});

app.on('activate', () => showWorkbench());
