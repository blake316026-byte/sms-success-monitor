import {
  app,
  BrowserWindow,
  ipcMain,
  Menu,
  Notification,
  safeStorage,
  shell,
  WebContentsView
} from 'electron';
import crypto from 'node:crypto';
import fs from 'node:fs';
import fsPromises from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { WithdrawalReports, reportKinds } from './withdrawal-reports.mjs';
import { WithdrawalNavigation } from './withdrawal-navigation.mjs';
import {
  ALERT_THRESHOLD,
  calculateMetrics,
  isAlert,
  isValidTotpSecret,
  MAX_CAPTCHA_LOGIN_ATTEMPTS,
  MAX_SAMPLE_LIMIT,
  MAX_TOTP_LOGIN_ATTEMPTS,
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
import {
  DEFAULT_PERSISTENT_HIGHLIGHT_SETTINGS,
  normalizePersistentHighlightSettings
} from './persistent-highlight-settings.mjs';

const currentDirectory = path.dirname(fileURLToPath(import.meta.url));
const clientRoot = path.resolve(currentDirectory, '..');
const sharedRoot = app.isPackaged
  ? path.join(process.resourcesPath, 'shared')
  : path.resolve(clientRoot, '../shared');
app.setPath('userData', path.join(app.getPath('appData'), 'SMS Platform Workbench'));
const modules = JSON.parse(fs.readFileSync(path.join(sharedRoot, 'modules.json'), 'utf8'));
const loginAutomationSource = fs.readFileSync(
  path.join(sharedRoot, 'auto-login/login-page.js'),
  'utf8'
);
const persistentHighlightSource = fs.readFileSync(
  path.join(sharedRoot, 'auto-login/persistent-highlight.js'),
  'utf8'
);
let shellHeight = 112;
const autoLoginCooldownMs = 5 * 60_000;
const financialRefreshIntervalMs = 20_000;

const pages = new Map();
const moduleStates = new Map();
const downloadSessions = new WeakSet();
let workbenchWindow;
let selectedPageId = modules[0]?.id || null;
let attachedView;
let quitting = false;
let customPagesPath;
let credentialsPath;
let settingsPath;
let credentialProfiles = {};
let sampleLimit = SAMPLE_LIMIT;
let workbenchZoomFactor = DEFAULT_WORKBENCH_ZOOM_FACTOR;
let persistentHighlightSettings = { ...DEFAULT_PERSISTENT_HIGHLIGHT_SETTINGS };
let disabledModuleIds = new Set();
let pausedMonitorIds = new Set();
let pausedFinanceIds = new Set();
let moduleDisplayNames = {};
let localAutomationServer;
let localAutomationWindow;
let localAutomationReady;
let localAutomationError;
let scanTimer;
let financeTimer;
let workbenchModalOpen = false;
const reportWindows = new Map();
const reportSnapshots = new Map();
let reports, withdrawalNavigation, reportTimer;

function reportSources() {
  return [...pages.values()].map(page => {
    const wc=page.view.webContents;
    let currentURL='',ready=false;
    try {
      currentURL=wc.getURL();
      ready=!wc.isDestroyed()&&!wc.isLoadingMainFrame()&&new URL(currentURL).origin===new URL(page.url).origin;
    } catch {}
    return {id:page.id,name:page.name,url:page.url,currentURL,ready,account:profileFor(page.id)?.username||'',
      allowNPG:!/^okbet$/i.test(page.name),wc};
  });
}

function initializeReports() {
  if(reports)return;
  const scripts=JSON.parse(fs.readFileSync(path.join(clientRoot,'build/query-scripts.json'),'utf8'));
  const cachePath=path.join(app.getPath('userData'),'withdrawal-reviewers-v1.encrypted');
  const test=process.env.SMS_MONITOR_LOCAL_AUTOMATION_CHECK==='1';
  const execute=async(source,key,args={})=>{
    const page=pages.get(source.id);
    if(!page||page.view.webContents!==source.wc||source.wc.isDestroyed())throw new Error('页面未就绪，就绪后自动补查');
    if(key==='cancel')return source.wc.executeJavaScript(args.kind==='pending'
      ?'window.__smsPendingOrdersRun=null;window.__smsPendingOrdersAbort?.abort();void 0'
      :'window.__smsReviewerRun=null;window.__smsReviewerAbort?.abort();void 0');
    if(key==='invalidateNavigation')return source.wc.executeJavaScript(`window.__workbenchNavigationID=${JSON.stringify(args.navID)};void 0`);
    if(new URL(source.wc.getURL()).origin!==new URL(source.url).origin)throw new Error('平台地址已变化');
    let code=scripts[key];
    if(!code)throw new Error('不支持的查询');
    if(args.navID) {
      const guard=`if(window.__workbenchNavigationID!==${JSON.stringify(args.navID)})throw new Error('已切换到新的查询');`;
      code=code.replace('const capture = () => {','const capture = () => {'+guard)
        .replace('const pause = () => new Promise(resolve => setTimeout(resolve, 160));',
          'const pause = async () => {await new Promise(resolve => setTimeout(resolve,160));'+guard+'};');
    }
    const names=Object.keys(args),values=Object.values(args);
    let timer;
    try {
      return await Promise.race([
        source.wc.executeJavaScript(`(async (${names.join(',')})=>{${code}\n})(...${JSON.stringify(values)})`),
        new Promise((_,reject)=>{timer=setTimeout(()=>{
          if(['pending','reviewers'].includes(key))void execute(source,'cancel',{kind:key}).catch(()=>{});
          reject(new Error('页面查询超时，请稍后重试'));
        },['pending','reviewers'].includes(key)?195000:key==='search'?22000:6000);})
      ]);
    } finally {clearTimeout(timer);}
  };
  reports=new WithdrawalReports({sources:reportSources,execute,scripts,
    load:()=>test?{}:JSON.parse(safeStorage.decryptString(fs.readFileSync(cachePath))),
    save:data=>{
      if(test)return;
      if(!safeStorage.isEncryptionAvailable())throw new Error('系统加密不可用');
      fs.mkdirSync(path.dirname(cachePath),{recursive:true});
      fs.writeFileSync(cachePath+'.tmp',safeStorage.encryptString(JSON.stringify(data)),{mode:0o600});
      fs.renameSync(cachePath+'.tmp',cachePath);
    },
    changed:(kind,snapshot)=>{
      const window=reportWindows.get(kind);
      const signature=JSON.stringify(snapshot);
      if(window&&!window.isDestroyed()&&reportSnapshots.get(kind)!==signature) {
        reportSnapshots.set(kind,signature);window.webContents.send('reports:changed',snapshot);
      }
    }});
  reports.persist();
  withdrawalNavigation=new WithdrawalNavigation({reports,source:id=>reportSources().find(s=>s.id===id),execute,
    show:id=>showWorkbench(id),selected:()=>selectedPageId,load:(source,url)=>source.wc.loadURL(url)});
  reportTimer=setInterval(()=>void reports.tick().catch(error=>console.warn('Report maintenance: '+error.message)),1000);
  reportTimer.unref();
}

function showReport(kind) {
  if(!reportKinds.includes(kind))throw new Error('未知查询');
  initializeReports();
  let window=reportWindows.get(kind);
  if(!window||window.isDestroyed()) {
    window=new BrowserWindow({width:1050,height:700,minWidth:620,minHeight:440,title:kind==='pending'?'全平台待处理订单':'提现审核人员查询',
      backgroundColor:'#ffffff',webPreferences:{preload:path.join(currentDirectory,'reports-preload.cjs'),nodeIntegration:false,contextIsolation:true,sandbox:true}});
    reportWindows.set(kind,window);
    window.webContents.setWindowOpenHandler(()=>({action:'deny'}));
    window.webContents.on('will-navigate',event=>event.preventDefault());
    window.on('closed',()=>{reportWindows.delete(kind);reports.close(kind);});
    void window.loadFile(uiPath('reports.html'));
  }
  void reports.open(kind);
  window.show();window.focus();return true;
}

function reportSender(event) {
  if(event.senderFrame!==event.sender.mainFrame)throw new Error('无权访问查询');
  for(const [kind,window] of reportWindows)if(!window.isDestroyed()&&window.webContents===event.sender)return kind;
  throw new Error('无权访问查询');
}

for (const module of modules) {
  moduleStates.set(module.id, {
    ...module,
    monitored: true,
    status: 'starting',
    message: '等待连接',
    metrics: null,
    dailyFinancial: null,
    financeMessage: '等待首次财务查询',
    financeRefreshing: false,
    financeGeneration: 0,
    smsPermissionBlocked: false,
    financePermissionBlocked: false,
    scannedAt: null,
    nextScanAt: null,
    scanning: false,
    consecutiveScanFailures: 0,
    captchaAutoLoginAttempts: 0,
    totpAutoLoginAttempts: 0,
    autoLoginInProgress: false,
    autoLoginStage: '',
    autoLoginCooldownUntil: 0,
    autoLoginTimer: null,
    pageSessionRecoveryAttempted: false,
    apiAuthenticationValidationAttempted: false,
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
  const workbenchCheckView = new WebContentsView({
    webPreferences: { contextIsolation: true, nodeIntegration: false, sandbox: true }
  });
  const workbenchCheckWindow = new BrowserWindow({
    width: 400,
    height: 300,
    show: false
  });
  workbenchCheckView.setBounds({ x: 0, y: 0, width: 400, height: 300 });
  workbenchCheckWindow.contentView.addChildView(workbenchCheckView);
  workbenchCheckWindow.showInactive();
  try {
    await workbenchCheckView.webContents.loadURL(
      `data:text/html;charset=utf-8,${encodeURIComponent('<p>monitor find check</p><p>monitor find check</p>')}`
    );
    workbenchCheckView.webContents.focus();
    await new Promise((resolve) => setTimeout(resolve, 250));
    workbenchCheckView.webContents.setZoomFactor(1.25);
    if (Math.abs(workbenchCheckView.webContents.getZoomFactor() - 1.25) > 0.001) {
      throw new Error('Windows WebContentsView zoom factor did not apply');
    }
    const findResult = await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        workbenchCheckView.webContents.removeListener('found-in-page', onFoundInPage);
        reject(new Error('Windows WebContentsView page find timed out'));
      }, 5_000);
      const onFoundInPage = (_event, result) => {
        if (!result.finalUpdate) return;
        clearTimeout(timeout);
        workbenchCheckView.webContents.removeListener('found-in-page', onFoundInPage);
        resolve(result);
      };
      workbenchCheckView.webContents.on('found-in-page', onFoundInPage);
      workbenchCheckView.webContents.findInPage('monitor find check', { findNext: true });
    });
    if (findResult.matches !== 2) {
      throw new Error(`Windows WebContentsView page find returned ${findResult.matches} matches`);
    }
    workbenchCheckView.webContents.stopFindInPage('clearSelection');
    const highlightResult = await workbenchCheckView.webContents.executeJavaScript(
      `(async () => { ${persistentHighlightSource}\n`
        + `const initial = globalThis.smsPersistentHighlighter.configure({`
        + `enabled:true,terms:['monitor','dynamic term'],color:'#fff176',wholeWords:false});`
        + `const p=document.createElement('p');p.textContent='dynamic term';document.body.appendChild(p);`
        + `await new Promise(resolve=>setTimeout(resolve,300));`
        + `return {supported:initial.supported,initialCount:initial.count,`
        + `finalCount:CSS.highlights.get('sms-monitor-persistent-highlight')?.size||0};})()`
    );
    if (!highlightResult.supported
      || highlightResult.initialCount !== 2
      || highlightResult.finalCount !== 3) {
      throw new Error('Windows persistent page highlighting did not refresh');
    }
  } finally {
    workbenchCheckWindow.contentView.removeChildView(workbenchCheckView);
    workbenchCheckView.webContents.close();
    workbenchCheckWindow.destroy();
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
  await verifyPublicWorkbench();
}

async function verifyPublicWorkbench() {
  const id = '__public-workbench-test__';
  const view = createRemotePage({ id, name: 'Local test', url: 'data:text/html,<p>Local page</p>', monitored: false });
  selectedPageId = id;
  registerIPC();
  createApplicationMenu();
  createWorkbenchWindow();
  const errors = [];
  workbenchWindow.webContents.on('console-message', (_event, details) => {
    if (details?.level === 'error') errors.push(details.message);
  });
  await new Promise(resolve => workbenchWindow.webContents.once('did-finish-load', resolve));
  await new Promise(resolve => setTimeout(resolve, 300));
  const valid = await workbenchWindow.webContents.executeJavaScript(`(() => {
    const api = window.smsApi;
    return !!document.querySelector('#add') && !!document.querySelector('#credentials')
      && !!document.querySelector('#pending-orders') && !!document.querySelector('#withdrawal-reviewers')
      && document.querySelectorAll('.tab-button').length === 1
      && !document.querySelector('#detail, #scan, #sample-limit')
      && !api.showDetail && !api.showWidgetMenu && !api.setMonitoringEnabled;
  })()`);
  const menus = JSON.stringify(Menu.getApplicationMenu().items.map(item => ({
    label: item.label, children: item.submenu?.items.map(child => child.label)
  })));
  if (!valid || errors.length || /监控总览|国家总计|扫描全部/.test(menus)
      || scanTimer || financeTimer) throw new Error('Public workbench UI or renderer check failed: ' + errors.join('; '));
  workbenchWindow.setSize(640,800);
  await new Promise(resolve=>setTimeout(resolve,200));
  if(!await workbenchWindow.webContents.executeJavaScript('document.querySelector(".browser-toolbar").scrollWidth<=innerWidth'))throw new Error('Workbench query controls overflow');
  workbenchWindow.setSize(1260,800);
  await verifyWithdrawalRuntime();
  showWorkbench(id);
  workbenchWindow.contentView.removeChildView(view);
  view.webContents.close();
  pages.delete(id);
  console.log('PASS: public workbench renderer, retained controls, menu and removed IPC');
}

async function verifyWithdrawalRuntime() {
  const server=http.createServer((_request,response)=>response.writeHead(200,{'Content-Type':'text/html'}).end('<html><body></body></html>'));
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const origin=`http://127.0.0.1:${server.address().port}`,id='__withdrawal-runtime-test__';
  const view=createRemotePage({id,name:'Example NPG / TC',url:origin+'/20008',monitored:false});
  try {
    await new Promise(resolve=>view.webContents.once('did-finish-load',resolve));
    showWorkbench(id);
    const fixture=fs.readFileSync(path.join(clientRoot,'build/query-fixture.js'),'utf8').replaceAll('https://orders-test.invalid',origin);
    const valid=await view.webContents.executeJavaScript(`(async()=>{${fixture}})()`);
    if(!valid)throw new Error('Withdrawal search fixture failed at '+await view.webContents.executeJavaScript('window.fixtureStep'));
    console.log('PASS: Electron NPG/TC sequential order, reviewer and platform searches, exact dates, authoritative totals and no reload');
    showReport('reviewers');
    const reviewerWindow=reportWindows.get('reviewers');
    await new Promise(resolve=>reviewerWindow.webContents.once('did-finish-load',resolve));
    await new Promise(resolve=>setTimeout(resolve,250));
    // Populate the host model, then exercise the actual isolated renderer/IPC.
    const source=reportSources().find(s=>s.id===id),s=reports.states.reviewers;
    reports.reconcile('reviewers');
    Object.assign(s.rows.get(id),{people:Array.from({length:23},(_,n)=>({id:String(n),name:'Auditor '+n,count:n+1})),
      total:355,savedAt:Date.now(),message:'已获取'});
    reports.notify('reviewers');
    await new Promise(resolve=>setTimeout(resolve,100));
    const ui=await reviewerWindow.webContents.executeJavaScript(`(async()=>{
      if(document.querySelectorAll('tbody tr').length!==10 || !document.querySelector('#column-three').textContent.includes('276'))return false;
      document.querySelector('#next').click();
      if(!document.querySelector('#pagination').textContent.includes('2 / 3'))return false;
      document.querySelector('#filter').value='Auditor 22';document.querySelector('#filter').dispatchEvent(new Event('input'));
      if(document.querySelectorAll('tbody tr').length!==1 || !document.querySelector('#column-three').textContent.includes('23'))return false;
      document.querySelector('#filter').value='';document.querySelector('#filter').dispatchEvent(new Event('input'));
      document.querySelector('#status-tab').click();
      return document.querySelector('tbody .link')!==null && document.querySelector('#column-three').textContent.includes('355') && !window.smsApi;
    })()`);
    if(!ui)throw new Error('Reviewer pagination, filter, platform total or IPC isolation failed');
    // Drive the production host navigation and generated script, not only the fixture body.
    await view.webContents.executeJavaScript(`(() => {
      sessionStorage.setItem('environment','');
      window.fetch=async()=>new Response(JSON.stringify({success:true,totalPageCount:412,value:[]}));
      document.querySelector('button').onclick=()=>{
        const state=document.querySelector('form').__reactFiber$fixture.memoizedProps.form.getFieldsValue();
        return fetch(location.origin+'/tac/api/relay/get/mcs-v3-player-withdraw-search?'+new URLSearchParams({
          merchantCode:'m',reviewOperator:state.reviewOperator||'',searchDateMode:state.searchDateMode,
          startDate:state.date[0].format().replaceAll('/','-'),endDate:state.date[1].format().replaceAll('/','-')}),{});
      };
    })()`);
    for(const all of [true,false]) {
      const result=await reviewerWindow.webContents.executeJavaScript(`window.reportApi.navigate(${JSON.stringify({platformID:id,all,id:'0'})})`);
      if(!result.ok)throw new Error('Host query navigation failed: '+result.message);
      if(await view.webContents.executeJavaScript('window.reuseSentinel')!==12345)throw new Error('Host query navigation reloaded a warm page');
    }
    if(s.rows.get(id).total!==412||s.rows.get(id).people[0].count!==412)throw new Error('Server total did not reach report model');
    const previous=s.settings;
    await reviewerWindow.webContents.executeJavaScript(`window.reportApi.configure({start:${JSON.stringify(s.start)},end:${JSON.stringify(s.end)},settings:{auto:false,interval:17}})`);
    if(reports.states.reviewers.settings.interval!==17||reports.states.reviewers.settings.auto)throw new Error('Reviewer settings IPC failed');
    s.settings=previous;
    // Assert layout at the minimum window width and save a native screenshot.
    for(const width of [1050,640]) {
      reviewerWindow.setSize(width,700);
      await new Promise(resolve=>setTimeout(resolve,150));
      const fits=await reviewerWindow.webContents.executeJavaScript('document.documentElement.scrollWidth<=innerWidth && document.querySelector("footer").getBoundingClientRect().bottom<=innerHeight');
      if(!fits)throw new Error('Query window overflows at '+width);
      if(process.env.SMS_MONITOR_LOCAL_AUTOMATION_RESULT) {
        const picture=await reviewerWindow.webContents.capturePage();
        await fsPromises.writeFile(path.join(path.dirname(process.env.SMS_MONITOR_LOCAL_AUTOMATION_RESULT),`reviewers-${width}.png`),picture.toPNG());
      }
    }
    reviewerWindow.destroy();
    showReport('pending');
    const pendingWindow=reportWindows.get('pending');
    await new Promise(resolve=>pendingWindow.webContents.once('did-finish-load',resolve));
    const pendingUI=await pendingWindow.webContents.executeJavaScript('!!window.reportApi && !window.smsApi && !!document.querySelector("#fetch")');
    if(!pendingUI)throw new Error('Pending window IPC or controls missing');
    pendingWindow.destroy();
    console.log('PASS: Windows query windows, pagination, filtering, totals, refresh settings, responsive layout and isolated IPC');
  } finally {
    if(attachedView===view){workbenchWindow.contentView.removeChildView(view);attachedView=null;}
    view.webContents.close();pages.delete(id);moduleStates.delete(id);server.close();
  }
}

async function runPackagedLocalAutomationCheck() {
  let timeout;
  try {
    await Promise.race([
      performPackagedLocalAutomationCheck(),
      new Promise((_, reject) => {
        timeout = setTimeout(
          () => reject(new Error('Packaged Windows local automation check exceeded 150 seconds')),
          150_000
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
    persistentHighlightSettings = normalizePersistentHighlightSettings(
      stored?.persistentHighlightSettings
    );
    disabledModuleIds = new Set(
      Array.isArray(stored?.disabledModuleIds)
        ? stored.disabledModuleIds.filter((id) => modules.some((module) => module.id === id))
        : []
    );
    pausedMonitorIds = new Set(
      Array.isArray(stored?.pausedMonitorIds) ? stored.pausedMonitorIds : []
    );
    pausedFinanceIds = new Set(
      Array.isArray(stored?.pausedFinanceIds)
        ? stored.pausedFinanceIds : [...pausedMonitorIds]
    );
    moduleDisplayNames = Object.fromEntries(
      Object.entries(stored?.moduleDisplayNames || {}).filter(([id, name]) =>
        modules.some((module) => module.id === id) && String(name).trim()
      )
    );
  } catch (_) {
    sampleLimit = SAMPLE_LIMIT;
    workbenchZoomFactor = DEFAULT_WORKBENCH_ZOOM_FACTOR;
    persistentHighlightSettings = { ...DEFAULT_PERSISTENT_HIGHLIGHT_SETTINGS };
    disabledModuleIds = new Set();
    pausedMonitorIds = new Set();
    pausedFinanceIds = new Set();
    moduleDisplayNames = {};
  }
}

async function saveMonitorSettings() {
  await fsPromises.mkdir(path.dirname(settingsPath), { recursive: true });
  await fsPromises.writeFile(
    settingsPath,
    `${JSON.stringify({
      version: 3,
      sampleLimit,
      workbenchZoomFactor,
      persistentHighlightSettings,
      disabledModuleIds: [...disabledModuleIds],
      pausedMonitorIds: [...pausedMonitorIds],
      pausedFinanceIds: [...pausedFinanceIds],
      moduleDisplayNames
    }, null, 2)}\n`,
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

function requiresInteractiveAuthentication(value) {
  try {
    return ['/ga-auth', '/unlock-ip'].includes(new URL(value).pathname);
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

function applyPageZoom(page, factor = workbenchZoomFactor) {
  if (!page || page.view.webContents.isDestroyed()) return false;
  try {
    page.view.webContents.setZoomFactor(factor);
    return Math.abs(page.view.webContents.getZoomFactor() - factor) <= 0.001;
  } catch (error) {
    console.warn(`[SMSMonitor] ${page.id} zoom failed: ${error.message}`);
    return false;
  }
}

function applyWorkbenchZoom() {
  let appliedCount = 0;
  const selected = pages.get(selectedPageId);
  if (applyPageZoom(selected)) appliedCount += 1;
  for (const page of pages.values()) {
    if (page === selected) continue;
    if (applyPageZoom(page)) appliedCount += 1;
  }
  return appliedCount;
}

async function applyPersistentHighlights(page) {
  if (!page || page.view.webContents.isDestroyed()) {
    return { supported: false, count: 0 };
  }
  try {
    return await page.view.webContents.executeJavaScript(
      `(async () => { ${persistentHighlightSource}\n`
        + `return globalThis.smsPersistentHighlighter.configure(`
        + `${JSON.stringify(persistentHighlightSettings)}); })()`
    );
  } catch (error) {
    console.warn(`[SMSMonitor] ${page.id} persistent highlight failed: ${error.message}`);
    return { supported: false, count: 0 };
  }
}

async function applyPersistentHighlightsToAllPages() {
  const results = await Promise.all([...pages.values()].map(applyPersistentHighlights));
  return results.filter((result) => result?.supported).length;
}

async function changeWorkbenchZoom(direction) {
  const nextFactor = nextWorkbenchZoomFactor(workbenchZoomFactor, direction);
  if (nextFactor === workbenchZoomFactor) {
    return { ok: true, zoomPercent: Math.round(workbenchZoomFactor * 100) };
  }

  const previousFactor = workbenchZoomFactor;
  workbenchZoomFactor = nextFactor;
  const appliedCount = applyWorkbenchZoom();
  const selected = pages.get(selectedPageId);
  if (selected && !selected.view.webContents.isDestroyed()
    && Math.abs(selected.view.webContents.getZoomFactor() - nextFactor) > 0.001) {
    workbenchZoomFactor = previousFactor;
    applyWorkbenchZoom();
    return { ok: false, message: '当前后台页面暂时无法缩放，请刷新页面后重试。' };
  }
  broadcastSnapshot();
  try {
    await saveMonitorSettings();
  } catch (error) {
    workbenchZoomFactor = previousFactor;
    applyWorkbenchZoom();
    broadcastSnapshot();
    return { ok: false, message: `无法保存缩放设置：${error.message}` };
  }
  return {
    ok: true,
    zoomPercent: Math.round(workbenchZoomFactor * 100),
    appliedCount
  };
}

function ensurePageState(page) {
  if (moduleStates.has(page.id)) return moduleStates.get(page.id);
  const monitoringEnabled = !pausedMonitorIds.has(page.id);
  const financeEnabled = !pausedFinanceIds.has(page.id);
  const state = {
    ...page,
    monitoringEnabled,
    financeEnabled,
    status: monitoringEnabled ? 'starting' : 'disabled',
    message: monitoringEnabled ? '等待连接'
      : financeEnabled ? '仅查询今日充值与提现' : '已停止短信和财务查询',
    metrics: null,
    dailyFinancial: null,
    financeMessage: '等待首次财务查询',
    financeRefreshing: false,
    smsPermissionBlocked: false,
    financePermissionBlocked: false,
    scannedAt: null,
    nextScanAt: null,
    scanning: false,
    consecutiveScanFailures: 0,
    captchaAutoLoginAttempts: 0,
    totpAutoLoginAttempts: 0,
    autoLoginInProgress: false,
    autoLoginStage: '',
    autoLoginCooldownUntil: 0,
    autoLoginTimer: null,
    pageSessionRecoveryAttempted: false,
    apiAuthenticationValidationAttempted: false,
    needsImmediateScan: true
  };
  moduleStates.set(page.id, state);
  return state;
}

function createRemotePage(page) {
  ensurePageState(page);
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
  configureDownloads(view.webContents.session);
  view.webContents.setWindowOpenHandler(({ url }) => {
    view.webContents.loadURL(url);
    return { action: 'deny' };
  });
  view.webContents.on('did-finish-load', () => {
    applyPageZoom({ id: page.id, view });
    void applyPersistentHighlights({ id: page.id, view });
    handlePageFinished(page.id);
    if (moduleStates.get(page.id)?.financeEnabled) {
      setTimeout(() => refreshFinancialModule(page.id), 900);
    }
  });
  view.webContents.on('did-start-loading', () => broadcastSnapshot());
  view.webContents.on('did-stop-loading', () => broadcastSnapshot());
  view.webContents.on('did-navigate', () => broadcastSnapshot());
  view.webContents.on('did-navigate-in-page', () => broadcastSnapshot());
  view.webContents.on('zoom-changed', (_event, direction) => {
    void changeWorkbenchZoom(direction);
  });
  view.webContents.on('found-in-page', (_event, result) => {
    if (page.id !== selectedPageId || !workbenchWindow || workbenchWindow.isDestroyed()) return;
    workbenchWindow.webContents.send('find:result', { pageId: page.id, ...result });
  });
  view.webContents.on('render-process-gone', () => {
    if (quitting) return;
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
    if (!isMainFrame || code === -3) return;
    const recovering = handleScanFailure(page.id, `页面加载失败：${description}`);
    if (!recovering && !validatedURL) view.webContents.loadURL(page.url);
  });
  pages.set(page.id, { ...page, view });
  view.webContents.loadURL(page.url);
  return view;
}

function availableDownloadPath(filename) {
  const downloadsDirectory = app.getPath('downloads');
  const safeName = path.basename(String(filename || '').trim()) || 'download';
  const extension = path.extname(safeName);
  const baseName = path.basename(safeName, extension);
  let candidate = path.join(downloadsDirectory, safeName);
  for (let index = 2; fs.existsSync(candidate) && index < 10_000; index += 1) {
    candidate = path.join(downloadsDirectory, `${baseName} (${index})${extension}`);
  }
  return candidate;
}

function configureDownloads(targetSession) {
  if (downloadSessions.has(targetSession)) return;
  downloadSessions.add(targetSession);
  targetSession.on('will-download', (_event, item) => {
    const destination = availableDownloadPath(item.getFilename());
    item.setSavePath(destination);
    item.once('done', (_doneEvent, state) => {
      if (state === 'completed') {
        shell.showItemInFolder(destination);
        return;
      }
      new Notification({
        title: '文件下载失败',
        body: `${path.basename(destination)}：${state}`
      }).show();
    });
  });
}

async function handlePageFinished(id) {
  const page = pages.get(id);
  if (!page) return;
  const state = moduleStates.get(id);
  if (!state || (!state.monitoringEnabled && !state.financeEnabled)) return;
  const currentURL = page.view.webContents.getURL();
  if (requiresInteractiveAuthentication(currentURL)) {
    handleAuthenticationRequired(id, '平台需要重新登录。');
    return;
  }
  if (!isConfiguredOrigin(state, currentURL)) return;
  if (new URL(currentURL).pathname === '/login') {
    if (!state.monitoringEnabled) {
      handleAuthenticationRequired(id, '平台需要重新登录。');
      return;
    }
    if (!state.autoLoginInProgress && state.needsImmediateScan) {
      state.needsImmediateScan = false;
      setTimeout(() => scanModule(id), 900);
    } else {
      broadcastSnapshot();
    }
    return;
  }
  resetAutoLoginState(state);
  persistCurrentToken(id);
  if (!state.needsImmediateScan) {
    broadcastSnapshot();
    return;
  }
  state.needsImmediateScan = false;
  if (state.monitoringEnabled) setTimeout(() => scanModule(id), 900);
  else broadcastSnapshot();
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
  if (isAuthenticationURL(page.view.webContents.getURL())) return;
  const expectedUsername = profileFor(id).username;
  let token = '';
  try {
    token = await runLoginPageAction(
      page,
      `globalThis.smsLoginAutomation.extractToken(${JSON.stringify(expectedUsername)})`
    );
  } catch (_) {
    // The site WebView remains the primary local token store.
  }
  if (profileFor(id)?.username !== expectedUsername) return;
  await updateStoredToken(id, token);
}

function resetAutoLoginState(state) {
  state.captchaAutoLoginAttempts = 0;
  state.totpAutoLoginAttempts = 0;
  state.autoLoginInProgress = false;
  state.autoLoginStage = '';
  state.autoLoginCooldownUntil = 0;
  state.pageSessionRecoveryAttempted = false;
  state.apiAuthenticationValidationAttempted = false;
  if (state.autoLoginTimer) clearTimeout(state.autoLoginTimer);
  state.autoLoginTimer = null;
}

function pauseAutoLogin(id, phaseName, maximumAttempts, detail = '') {
  const state = moduleStates.get(id);
  if (!state) return;
  state.autoLoginInProgress = false;
  state.autoLoginStage = '';
  state.autoLoginCooldownUntil = Date.now() + autoLoginCooldownMs;
  const suffix = detail ? `（${detail}）` : '';
  updateModule(id, {
    status: 'auth',
    message: `${phaseName}已连续失败 ${maximumAttempts} 次${suffix}，请人工处理；自动登录暂停至 ${timeText(state.autoLoginCooldownUntil)}。`,
    metrics: null,
    nextScanAt: Date.now() + SCAN_INTERVAL_MS
  });
}

function pauseForManualLogin(id) {
  const state = moduleStates.get(id);
  if (!state) return;
  state.autoLoginInProgress = false;
  state.autoLoginStage = '';
  if (state.autoLoginTimer) clearTimeout(state.autoLoginTimer);
  state.autoLoginTimer = null;
  updateModule(id, {
    status: 'auth',
    message: '检测到人工输入，自动登录已暂停，请完成验证码登录。',
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
  const isTotp = (() => {
    try { return new URL(page.view.webContents.getURL()).pathname === '/ga-auth'; } catch (_) { return false; }
  })();
  const attemptsKey = isTotp ? 'totpAutoLoginAttempts' : 'captchaAutoLoginAttempts';
  const phaseName = isTotp ? 'Google 验证码' : '图片验证码';
  const maximumAttempts = isTotp
    ? MAX_TOTP_LOGIN_ATTEMPTS
    : MAX_CAPTCHA_LOGIN_ATTEMPTS;
  state[attemptsKey] += 1;
  if (state[attemptsKey] >= maximumAttempts) {
    pauseAutoLogin(id, phaseName, maximumAttempts, message);
    return;
  }
  updateModule(id, {
    status: 'starting',
    message: `${message}，将继续尝试${phaseName}（${state[attemptsKey] + 1}/${maximumAttempts}）`,
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
  state.smsPermissionBlocked = false;
  state.financePermissionBlocked = false;
  if (token) await updateStoredToken(id, token);
  await persistCurrentToken(id);
  state.needsImmediateScan = true;
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
  if (state.financeEnabled) setTimeout(() => refreshFinancialModule(id), 900);
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
  if (moduleStates.get(id)?.manualAuthenticationRequired) return;
  const state = moduleStates.get(id);
  const page = pages.get(id);
  const profile = profileFor(id);
  if (!state || !page || state.autoLoginInProgress || !canAutoLogin(profile)) return;

  if (state.autoLoginCooldownUntil && state.autoLoginCooldownUntil <= Date.now()) {
    state.captchaAutoLoginAttempts = 0;
    state.totpAutoLoginAttempts = 0;
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

  const isTotp = pathName === '/ga-auth';
  const attempts = isTotp
    ? state.totpAutoLoginAttempts
    : state.captchaAutoLoginAttempts;
  const maximumAttempts = isTotp
    ? MAX_TOTP_LOGIN_ATTEMPTS
    : MAX_CAPTCHA_LOGIN_ATTEMPTS;
  const phaseName = isTotp ? 'Google 验证码' : '图片验证码';
  if (attempts >= maximumAttempts) {
    pauseAutoLogin(id, phaseName, maximumAttempts);
    return;
  }

  state.autoLoginInProgress = true;
  updateModule(id, {
    status: 'starting',
    message: `正在自动登录（${phaseName} ${attempts + 1}/${maximumAttempts}）`,
    metrics: null,
    nextScanAt: Date.now() + SCAN_INTERVAL_MS
  });

  try {
    const snapshot = await runLoginPageAction(
      page,
      'globalThis.smsLoginAutomation.snapshot()'
    );
    if (snapshot?.kind === 'manual') {
      pauseForManualLogin(id);
      return;
    }
    if (snapshot?.kind === 'login') {
      if (!snapshot.captchaDataUrl) {
        retryAutoLogin(id, '验证码图片尚未加载');
        return;
      }
      const captcha = await callLocalAutomation('recognize', snapshot.captchaDataUrl);
      if (!/^[0-9A-Za-z]{4}$/.test(String(captcha || ''))) {
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
      if (submitted?.manual) {
        pauseForManualLogin(id);
        return;
      }
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
      if (!isValidTotpSecret(secret)) {
        state.autoLoginInProgress = false;
        profile.token = '';
        await saveCredentialProfiles();
        updateModule(id, {
          status: 'auth',
          message: 'Google 密钥格式无效，请重新保存原始 Base32 密钥或完整 otpauth:// 链接。',
          metrics: null
        });
        return;
      }
      const rawServerOffset = Number(snapshot.clockOffsetMs);
      const serverOffsetMs = Number.isFinite(rawServerOffset)
        && Math.abs(rawServerOffset) <= 43_200_000
        ? rawServerOffset
        : 0;
      const retryOffsetsMs = [0, -30_000, 30_000, -60_000, 60_000];
      const offsetMs = serverOffsetMs
        + retryOffsetsMs[Math.min(state.totpAutoLoginAttempts, retryOffsetsMs.length - 1)];
      const cyclePosition = Math.floor(((Date.now() + offsetMs) / 1000) % 30);
      if (cyclePosition > 24) {
        await new Promise((resolve) => setTimeout(resolve, 6500));
        if (!state.autoLoginInProgress) return;
      }
      const code = await callLocalAutomation('generateTotp', secret, Date.now() + offsetMs);
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
  if (!state || !page || (!state.monitoringEnabled && !state.financeEnabled)) return;
  state.scanning = false;
  state.consecutiveScanFailures = 0;
  state.needsImmediateScan = true;
  state.nextScanAt = Date.now() + SCAN_INTERVAL_MS;
  state.metrics = null;
  state.dailyFinancial = null;
  if (state.manualAuthenticationRequired) {
    state.autoLoginInProgress = false;
    if (state.autoLoginTimer) clearTimeout(state.autoLoginTimer);
    updateModule(id, { status: 'auth', message: '当前账号会话失效，请人工确认登录账号；不会改用旧账号。' });
    return;
  }
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

function handleAPIAuthenticationRequired(id, result, fallbackMessage) {
  const state = moduleStates.get(id);
  const page = pages.get(id);
  if (!state || !page || (!state.monitoringEnabled && !state.financeEnabled)) return;
  const message = result?.message || fallbackMessage;
  const currentURL = page.view.webContents.getURL();

  if (result?.manualOnly || requiresInteractiveAuthentication(currentURL)) {
    if (result?.manualOnly) state.manualAuthenticationRequired = true;
    handleAuthenticationRequired(id, message);
    return;
  }

  const sessionRejected = result?.httpStatus === 401 || result?.authCode === 1012;
  if (sessionRejected && !state.apiAuthenticationValidationAttempted) {
    state.apiAuthenticationValidationAttempted = true;
    state.needsImmediateScan = true;
    updateModule(id, {
      status: 'starting',
      message: '接口登录态异常，正在刷新当前页面确认',
      metrics: null,
      dailyFinancial: null,
      nextScanAt: null
    });
    page.view.webContents.reload();
    return;
  }

  updateModule(id, {
    status: 'error',
    message: `${message} 已保留当前网页会话，请检查对应页面的验证提示。`,
    metrics: null,
    dailyFinancial: null,
    scannedAt: Date.now(),
    nextScanAt: Date.now() + SCAN_INTERVAL_MS
  });
}

function handleScanFailure(id, message) {
  const state = moduleStates.get(id);
  const page = pages.get(id);
  if (!state || !page || !state.monitoringEnabled) return false;

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
  const page = pages.get(id);
  const state = moduleStates.get(id);
  if (!page || !state) return;
  const url = page.view.webContents.getURL();
  if (isAuthenticationURL(url)) {
    handleAuthenticationRequired(id, '平台需要登录。');
  } else {
    state.status = 'page';
    state.message = '后台页面';
    state.metrics = null;
    state.dailyFinancial = null;
    broadcastSnapshot();
  }
}

async function refreshFinancialModule() {}

function refreshAllFinancialModules() {}

function scanAllPages() {
  for (const page of pages.values()) scanModule(page.id);
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
  return {
    modules: [...moduleStates.values()].map(state => ({
      id: state.id, name: state.name, url: state.url, status: state.status, message: state.message
    })),
    pages: [...pages.values()].map(pageSnapshot),
    selectedPageId,
    workbenchZoomPercent: Math.round(workbenchZoomFactor * 100),
    minimumWorkbenchZoomPercent: Math.round(MIN_WORKBENCH_ZOOM_FACTOR * 100),
    maximumWorkbenchZoomPercent: Math.round(MAX_WORKBENCH_ZOOM_FACTOR * 100)
  };
}

function broadcastSnapshot() {
  const snapshot = buildSnapshot();
  for (const window of [workbenchWindow]) {
    if (window && !window.isDestroyed()) {
      window.webContents.send('snapshot:changed', snapshot);
    }
  }
}

function maybeNotify() {}

function attachSelectedView() {
  if (!workbenchWindow || workbenchWindow.isDestroyed()) return;
  if (workbenchModalOpen) return;
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

function setWorkbenchModalOpen(open) {
  workbenchModalOpen = Boolean(open);
  if (!workbenchWindow || workbenchWindow.isDestroyed()) return true;
  if (workbenchModalOpen) {
    if (attachedView) {
      workbenchWindow.contentView.removeChildView(attachedView);
      attachedView = null;
    }
    workbenchWindow.webContents.focus();
  } else {
    attachSelectedView();
  }
  return true;
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
    minWidth: 620,
    minHeight: 620,
    title: '后台工作台',
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
  workbenchWindow.on('closed', () => { workbenchWindow = null; app.quit(); });
  workbenchWindow.webContents.on('did-finish-load', () => {
    workbenchModalOpen = false;
    attachSelectedView();
    broadcastSnapshot();
  });
}

function createApplicationMenu() {
  const menu = Menu.buildFromTemplate([
    {
      label: '文件',
      submenu: [
        { label: '打开后台工作台', click: () => showWorkbench() },
        { label: '全平台待处理订单', click: () => showReport('pending') },
        { label: '提现审核人员查询', click: () => showReport('reviewers') },
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
        {
          label: '在当前后台中查找',
          accelerator: 'CmdOrCtrl+F',
          click: () => showWorkbenchFind()
        },
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

function showWorkbenchFind() {
  showWorkbench();
  workbenchWindow.webContents.send('find:show');
}

function showWorkbench(id) {
  if (id && pages.has(id)) selectedPageId = id;
  attachSelectedView();
  workbenchWindow.show();
  workbenchWindow.focus();
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
  state.manualAuthenticationRequired = false;
  state.smsPermissionBlocked = false;
  state.financePermissionBlocked = false;
  const currentURL = page.view.webContents.getURL();
  if (isAuthenticationURL(currentURL)) {
    handleAuthenticationRequired(id, '自动登录配置已更新。');
  }
}

function waitForPageReload(webContents, timeoutMs = 15_000) {
  return new Promise((resolve) => {
    let started = false;
    let fallbackTimer;
    const finish = (result) => {
      clearTimeout(fallbackTimer);
      webContents.removeListener('did-start-loading', onStart);
      webContents.removeListener('did-stop-loading', onStop);
      webContents.removeListener('did-fail-load', onFail);
      resolve(result);
    };
    const onStart = () => { started = true; };
    const onStop = () => finish(started
      ? { ok: true }
      : { ok: false, message: '页面没有开始刷新' });
    const onFail = (_event, code, description, _url, isMainFrame) => {
      if (isMainFrame && code !== -3) finish({ ok: false, message: `刷新失败：${description}` });
    };
    webContents.on('did-start-loading', onStart);
    webContents.on('did-stop-loading', onStop);
    webContents.on('did-fail-load', onFail);
    fallbackTimer = setTimeout(() => finish({ ok: false, message: '页面刷新超过 15 秒' }), timeoutMs);
  });
}

function registerIPC() {
  ipcMain.handle('reports:show',(event,kind)=>{
    if(event.sender!==workbenchWindow?.webContents||event.senderFrame!==event.sender.mainFrame)throw new Error('无权访问');
    return showReport(kind);
  });
  ipcMain.handle('reports:get',event=>reports.snapshot(reportSender(event)));
  ipcMain.handle('reports:configure',async(event,input)=>{
    try{return await reports.configure(reportSender(event),input);}catch(e){return {ok:false,message:e.message};}
  });
  ipcMain.handle('reports:fetch',event=>{
    const kind=reportSender(event);
    void reports.fetch(kind).catch(error=>{reports.states[kind].message=error.message;reports.notify(kind);});
    return {ok:true};
  });
  ipcMain.handle('reports:cancel',event=>{const kind=reportSender(event);reports.cancel(kind);return {ok:true};});
  ipcMain.handle('reports:navigate',async(event,input)=>{
    try {
      const kind=reportSender(event);
      if(!input||typeof input.platformID!=='string'||(input.all&&kind!=='reviewers'))throw new Error('查询参数无效');
      const target=reports.target(kind,input.platformID,input.id,input.all===true);
      return await withdrawalNavigation.open(target);
    } catch(e){return {ok:false,message:e.message};}
  });
  ipcMain.handle('snapshot:get', () => buildSnapshot());
  ipcMain.handle('page:select', (_event, id) => {
    if (!pages.has(id)) return false;
    pages.get(selectedPageId)?.view.webContents.stopFindInPage('clearSelection');
    selectedPageId = id;
    attachSelectedView();
    return true;
  });
  ipcMain.handle('page:navigate', (_event, value) => {
    const url = normalizeURL(value);
    const page = pages.get(selectedPageId);
    if (!url || !page) return false;
    if (!page.monitored) {
      page.url = url;
      const state = moduleStates.get(page.id);
      if (state) {
        state.url = url;
        state.metrics = null;
        state.status = 'starting';
        state.message = '后台地址已更新，正在重新连接';
        state.nextScanAt = null;
        state.needsImmediateScan = true;
      }
      saveCustomPages();
    }
    page.view.webContents.loadURL(url);
    broadcastSnapshot(page.id);
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
  ipcMain.handle('page:reload', async () => {
    const page = pages.get(selectedPageId);
    const state = moduleStates.get(selectedPageId);
    if (!page || !state || page.view.webContents.isDestroyed()) {
      return { ok: false, message: '当前平台页面不可用' };
    }
    state.smsPermissionBlocked = false;
    state.financePermissionBlocked = false;
    state.needsImmediateScan = true;
    state.message = '正在刷新平台页面';
    state.nextScanAt = null;
    broadcastSnapshot(page.id);
    try {
      const reloadResult = waitForPageReload(page.view.webContents);
      page.view.webContents.reloadIgnoringCache();
      let result = await reloadResult;
      if (!result.ok && page.view.webContents.getURL()) {
        const fallbackResult = waitForPageReload(page.view.webContents);
        await page.view.webContents.loadURL(page.view.webContents.getURL());
        result = await fallbackResult;
      }
      if (!result.ok) state.message = result.message;
      broadcastSnapshot(page.id);
      return result;
    } catch (error) {
      state.message = `刷新失败：${error.message}`;
      broadcastSnapshot(page.id);
      return { ok: false, message: state.message };
    }
  });
  ipcMain.handle('browser:clear-cache', async () => {
    const activePages = [...pages.values()].filter((page) => !page.view.webContents.isDestroyed());
    const sessions = [...new Set(activePages.map((page) => page.view.webContents.session))];
    try {
      await Promise.all(sessions.map(async (targetSession) => {
        await targetSession.clearCache();
        await targetSession.clearCodeCaches({});
        await targetSession.clearStorageData({
          storages: ['shadercache', 'serviceworkers', 'cachestorage']
        });
      }));
      for (const page of activePages) {
        page.view.webContents.reloadIgnoringCache();
      }
      return { ok: true, message: '网页缓存已清除，正在从源站重新加载' };
    } catch (error) {
      return { ok: false, message: `清除缓存失败：${error.message}` };
    }
  });
  ipcMain.handle('page:find', (_event, query, options) => {
    const page = pages.get(selectedPageId);
    const text = String(query || '');
    if (!page || page.view.webContents.isDestroyed()) {
      return { ok: false, message: '当前后台页面不可用' };
    }
    if (!text) {
      page.view.webContents.stopFindInPage('clearSelection');
      return { ok: true, requestId: null };
    }
    const requestId = page.view.webContents.findInPage(text, {
      forward: options?.forward !== false,
      findNext: options?.findNext !== false,
      matchCase: false
    });
    return { ok: true, requestId };
  });
  ipcMain.handle('page:stop-find', (_event, action = 'clearSelection') => {
    const page = pages.get(selectedPageId);
    if (!page || page.view.webContents.isDestroyed()) return false;
    const normalizedAction = ['clearSelection', 'keepSelection', 'activateSelection'].includes(action)
      ? action
      : 'clearSelection';
    page.view.webContents.stopFindInPage(normalizedAction);
    page.view.webContents.focus();
    return true;
  });
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
  ipcMain.handle('page:rename', async (_event, id, value) => {
    const page = pages.get(id);
    const name = String(value || '').trim();
    if (!page || !name) return { ok: false, message: '页面名称不能为空' };
    const previousName = page.name;
    const previousStoredName = moduleDisplayNames[id];
    page.name = name;
    const state = moduleStates.get(id);
    if (state) state.name = name;
    try {
      if (page.monitored) {
        moduleDisplayNames[id] = name;
        await saveMonitorSettings();
      } else {
        await saveCustomPages();
      }
    } catch (error) {
      page.name = previousName;
      if (state) state.name = previousName;
      if (page.monitored) {
        if (previousStoredName) moduleDisplayNames[id] = previousStoredName;
        else delete moduleDisplayNames[id];
      }
      return { ok: false, message: `无法保存页面名称：${error.message}` };
    }
    broadcastSnapshot();
    return { ok: true };
  });
  ipcMain.handle('page:close', async (_event, id) => {
    const page = pages.get(id);
    if (!page) return { ok: false, message: '所选平台已经不存在' };
    if (page.monitored) {
      disabledModuleIds.add(id);
      try {
        await saveMonitorSettings();
      } catch (error) {
        disabledModuleIds.delete(id);
        return { ok: false, message: `无法保存删除设置：${error.message}` };
      }
    }
    if (attachedView === page.view) {
      workbenchWindow.contentView.removeChildView(page.view);
      attachedView = null;
    }
    const state = moduleStates.get(id);
    if (state?.autoLoginTimer) clearTimeout(state.autoLoginTimer);
    moduleStates.delete(id);
    pages.delete(id);
    await page.view.webContents.session.clearStorageData();
    page.view.webContents.close();
    selectedPageId = pages.keys().next().value || null;
    try {
      if (!page.monitored) await saveCustomPages();
    } catch (error) {
      return { ok: false, message: `平台已关闭，但删除设置保存失败：${error.message}` };
    }
    attachSelectedView();
    broadcastSnapshot();
    return { ok: true };
  });
  ipcMain.handle('highlights:get', () => ({
    ok: true,
    settings: persistentHighlightSettings
  }));
  ipcMain.handle('highlights:save', async (_event, input) => {
    const previous = persistentHighlightSettings;
    persistentHighlightSettings = normalizePersistentHighlightSettings(input);
    try {
      await saveMonitorSettings();
      const appliedCount = await applyPersistentHighlightsToAllPages();
      return { ok: true, settings: persistentHighlightSettings, appliedCount };
    } catch (error) {
      persistentHighlightSettings = previous;
      await applyPersistentHighlightsToAllPages();
      return { ok: false, message: `无法保存自动高亮设置：${error.message}` };
    }
  });
  ipcMain.handle('workbench:zoom', (_event, direction) => {
    if (!['in', 'out', 'reset'].includes(direction)) {
      return { ok: false, message: '无法识别缩放操作' };
    }
    return changeWorkbenchZoom(direction);
  });
  ipcMain.handle('workbench:modal', (_event, open) => setWorkbenchModalOpen(open));
  ipcMain.on('workbench:shell-height', (_event, value) => {
    const nextHeight = Math.max(112, Math.min(320, Math.round(Number(value) || 112)));
    if (nextHeight === shellHeight) return;
    shellHeight = nextHeight;
    layoutSelectedView();
  });
  ipcMain.handle('credentials:get', (_event, id) => {
    const page = pages.get(id);
    if (!page) return { ok: false, message: '当前页面不存在' };
    return { ok: true, profile: credentialSummary(id) };
  });
  ipcMain.handle('credentials:save', async (_event, id, input) => {
    const page = pages.get(id);
    if (!page) return { ok: false, message: '当前页面不存在' };
    const existing = profileFor(id) || {};
    const username = String(input?.username || '').trim();
    const passwordInput = String(input?.password || '');
    const password = passwordInput || String(existing.password || '');
    if (!username || !password) return { ok: false, message: '账号和密码不能为空' };
    const totpSecret = input?.clearTotp
      ? ''
      : String(input?.totpSecret || '').trim() || String(existing.totpSecret || '');
    if (totpSecret && !isValidTotpSecret(totpSecret)) {
      return {
        ok: false,
        message: 'Google 密钥格式无效，请填写原始 Base32 密钥或完整 otpauth:// 链接'
      };
    }
    credentialProfiles[id] = {
      username,
      password,
      totpSecret,
      token: existing.username === username ? String(existing.token || '') : '',
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
    if (!page) return { ok: false, message: '当前页面不存在' };
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
  ipcMain.handle('app:quit', () => {
    quitting = true;
    app.quit();
  });

}

app.whenReady().then(async () => {
  app.setAppUserModelId('com.local.sms-success-monitor.public');
  if (process.env.SMS_MONITOR_LOCAL_AUTOMATION_CHECK === '1') {
    const resultPath = process.env.SMS_MONITOR_LOCAL_AUTOMATION_RESULT || '';
    let exitCode = 0;
    let message = 'PASS: packaged Windows DPAPI, OCR, TOTP, workbench, NPG/TC withdrawal queries, repeated navigation, pagination, cache and totals checks passed';
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
  for (const module of modules) {
    if (!disabledModuleIds.has(module.id)) {
      createRemotePage({ ...module, name: moduleDisplayNames[module.id] || module.name, monitored: true });
    }
  }
  for (const page of await loadCustomPages()) createRemotePage(page);
  createWorkbenchWindow();

});

app.on('before-quit', () => {
  quitting = true;
  clearInterval(reportTimer);
  reports?.dispose();
  if (scanTimer) clearInterval(scanTimer);
  if (financeTimer) clearInterval(financeTimer);
  for (const state of moduleStates.values()) {
    if (state.autoLoginTimer) clearTimeout(state.autoLoginTimer);
  }
  localAutomationWindow?.destroy();
  localAutomationServer?.close();
});

app.on('window-all-closed', () => {});

app.on('activate', () => showWorkbench());
