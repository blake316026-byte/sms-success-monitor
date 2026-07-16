import {
  CircleCheck,
  ChevronLeft,
  ChevronRight,
  ChevronDown,
  ChevronUp,
  FileText,
  Hash,
  KeyRound,
  Lock,
  LockKeyhole,
  LoaderCircle,
  Plus,
  Pencil,
  Radar,
  RefreshCw,
  Search,
  TableProperties,
  TriangleAlert,
  WifiOff,
  X,
  ZoomIn,
  ZoomOut,
  createIcons
} from 'lucide';

const iconSet = {
  CircleCheck,
  ChevronLeft,
  ChevronRight,
  ChevronDown,
  ChevronUp,
  FileText,
  Hash,
  KeyRound,
  Lock,
  LockKeyhole,
  LoaderCircle,
  Plus,
  Pencil,
  Radar,
  RefreshCw,
  Search,
  TableProperties,
  TriangleAlert,
  WifiOff,
  X,
  ZoomIn,
  ZoomOut
};
let snapshot;
let lastSelectedPageId;
let findTimer;
let lastFindQuery = '';

const tabs = document.querySelector('#tabs');
const address = document.querySelector('#address');
const backButton = document.querySelector('#back');
const forwardButton = document.querySelector('#forward');
const reloadButton = document.querySelector('#reload');
const closeButton = document.querySelector('#close-page');
const renameButton = document.querySelector('#rename-page');
const credentialsButton = document.querySelector('#credentials');
const sampleLimitInput = document.querySelector('#sample-limit');
const zoomOutButton = document.querySelector('#zoom-out');
const zoomResetButton = document.querySelector('#zoom-reset');
const zoomInButton = document.querySelector('#zoom-in');
const findBar = document.querySelector('#find-bar');
const findInput = document.querySelector('#find-input');
const findCount = document.querySelector('#find-count');
const findPreviousButton = document.querySelector('#find-previous');
const findNextButton = document.querySelector('#find-next');
const dialog = document.querySelector('#add-dialog');
const pageName = document.querySelector('#page-name');
const pageURL = document.querySelector('#page-url');
const dialogError = document.querySelector('#dialog-error');
const credentialsDialog = document.querySelector('#credentials-dialog');
const credentialsTitle = document.querySelector('#credentials-title');
const credentialUsername = document.querySelector('#credential-username');
const credentialPassword = document.querySelector('#credential-password');
const credentialTotp = document.querySelector('#credential-totp');
const credentialClearTotp = document.querySelector('#credential-clear-totp');
const clearTotpRow = document.querySelector('#clear-totp-row');
const credentialEnabled = document.querySelector('#credential-enabled');
const credentialStatus = document.querySelector('#credential-status');
const credentialsError = document.querySelector('#credentials-error');
const removeCredentialsButton = document.querySelector('#remove-credentials');
let credentialModuleId;

async function showWorkbenchDialog(target) {
  await window.smsApi.setWorkbenchModalOpen(true);
  try {
    target.showModal();
  } catch (error) {
    await window.smsApi.setWorkbenchModalOpen(false);
    throw error;
  }
}

function restoreWorkbenchView() {
  if (!dialog.open && !credentialsDialog.open) {
    window.smsApi.setWorkbenchModalOpen(false);
  }
}

function statusIcon(status) {
  return {
    healthy: 'circle-check',
    alert: 'triangle-alert',
    auth: 'lock',
    error: 'wifi-off',
    scanning: 'loader-circle',
    starting: 'loader-circle',
    page: 'file-text'
  }[status] || 'file-text';
}

function render() {
  if (!snapshot) return;
  tabs.replaceChildren(...snapshot.pages.map((page) => {
    const button = document.createElement('button');
    button.className = `tab-button status-${page.status}`;
    button.dataset.id = page.id;
    button.role = 'tab';
    button.ariaSelected = String(page.id === snapshot.selectedPageId);
    if (page.id === snapshot.selectedPageId) button.classList.add('selected');
    button.innerHTML = `<i data-lucide="${statusIcon(page.status)}"></i><span>${escapeHTML(page.name)}</span>`;
    button.title = `${page.name} · ${statusLabel(page.status)}`;
    button.addEventListener('click', () => window.smsApi.selectPage(page.id));
    return button;
  }));

  const selected = snapshot.pages.find((page) => page.id === snapshot.selectedPageId);
  const selectionChanged = lastSelectedPageId && lastSelectedPageId !== snapshot.selectedPageId;
  lastSelectedPageId = snapshot.selectedPageId;
  if (selected) {
    address.value = selected.currentURL;
    backButton.disabled = !selected.canGoBack;
    forwardButton.disabled = !selected.canGoForward;
    closeButton.disabled = selected.monitored;
    renameButton.disabled = selected.monitored;
    credentialsButton.disabled = false;
    reloadButton.classList.toggle('loading', selected.loading);
  }
  if (document.activeElement !== sampleLimitInput) {
    sampleLimitInput.value = String(snapshot.sampleLimit);
    sampleLimitInput.min = String(snapshot.minimumSampleLimit);
    sampleLimitInput.max = String(snapshot.maximumSampleLimit);
  }
  zoomResetButton.textContent = `${snapshot.workbenchZoomPercent}%`;
  zoomOutButton.disabled = snapshot.workbenchZoomPercent <= snapshot.minimumWorkbenchZoomPercent;
  zoomInButton.disabled = snapshot.workbenchZoomPercent >= snapshot.maximumWorkbenchZoomPercent;
  createIcons({ icons: iconSet, attrs: { 'stroke-width': 2 } });
  if (selectionChanged && !findBar.hidden && findInput.value) {
    runFind(true, true);
  }
}

function openFind() {
  findBar.hidden = false;
  findInput.focus();
  findInput.select();
  if (findInput.value) runFind(true, true);
}

function closeFind() {
  clearTimeout(findTimer);
  lastFindQuery = '';
  findBar.hidden = true;
  findCount.textContent = '';
  findInput.classList.remove('not-found');
  window.smsApi.stopFindInPage('clearSelection');
}

function runFind(forward, findNext) {
  const query = findInput.value;
  findPreviousButton.disabled = !query;
  findNextButton.disabled = !query;
  if (!query) {
    lastFindQuery = '';
    findCount.textContent = '';
    findInput.classList.remove('not-found');
    window.smsApi.stopFindInPage('clearSelection');
    return;
  }
  const beginNewSession = findNext || query !== lastFindQuery;
  lastFindQuery = query;
  findCount.textContent = '...';
  window.smsApi.findInPage(query, { forward, findNext: beginNewSession });
}

function statusLabel(status) {
  return {
    healthy: '正常',
    alert: '报警',
    auth: '需登录',
    error: '异常',
    scanning: '扫描中',
    starting: '等待连接',
    page: '独立页面'
  }[status] || status;
}

function escapeHTML(value) {
  const span = document.createElement('span');
  span.textContent = value;
  return span.innerHTML;
}

document.querySelector('#address-form').addEventListener('submit', (event) => {
  event.preventDefault();
  window.smsApi.navigate(address.value);
});
backButton.addEventListener('click', () => window.smsApi.goBack());
forwardButton.addEventListener('click', () => window.smsApi.goForward());
reloadButton.addEventListener('click', () => window.smsApi.reload());
sampleLimitInput.addEventListener('change', async () => {
  const result = await window.smsApi.setSampleLimit(sampleLimitInput.value);
  if (!result.ok) {
    sampleLimitInput.setCustomValidity(result.message);
    sampleLimitInput.reportValidity();
    sampleLimitInput.value = String(snapshot.sampleLimit);
    return;
  }
  sampleLimitInput.setCustomValidity('');
  sampleLimitInput.value = String(result.sampleLimit);
});
zoomOutButton.addEventListener('click', () => window.smsApi.changeWorkbenchZoom('out'));
zoomResetButton.addEventListener('click', () => window.smsApi.changeWorkbenchZoom('reset'));
zoomInButton.addEventListener('click', () => window.smsApi.changeWorkbenchZoom('in'));
document.querySelector('#scan').addEventListener('click', () => {
  const selected = snapshot?.pages.find((page) => page.id === snapshot.selectedPageId);
  if (selected) window.smsApi.scan(selected.id);
});
document.querySelector('#detail').addEventListener('click', () => window.smsApi.showDetail());
document.querySelector('#find').addEventListener('click', openFind);
credentialsButton.addEventListener('click', async () => {
  const selected = snapshot?.pages.find((page) => page.id === snapshot.selectedPageId);
  if (!selected) return;
  const result = await window.smsApi.getCredentials(selected.id);
  if (!result.ok) return;
  credentialModuleId = selected.id;
  const profile = result.profile;
  credentialsTitle.textContent = `${selected.name} 自动登录`;
  credentialUsername.value = profile.username || '';
  credentialPassword.value = '';
  credentialPassword.placeholder = profile.passwordConfigured ? '已保存，留空保持不变' : '后台密码';
  credentialTotp.value = '';
  credentialTotp.placeholder = profile.totpConfigured
    ? '已保存，留空保持不变'
    : '没有二次验证可留空';
  credentialEnabled.checked = profile.configured ? profile.autoLoginEnabled : true;
  credentialClearTotp.checked = false;
  clearTotpRow.hidden = !profile.totpConfigured;
  removeCredentialsButton.disabled = !profile.configured;
  credentialStatus.textContent = profile.tokenConfigured
    ? '本地 Token：已加密保存'
    : '本地 Token：登录成功后自动保存';
  credentialsError.textContent = '';
  await showWorkbenchDialog(credentialsDialog);
  credentialUsername.focus();
});
document.querySelector('#add').addEventListener('click', async () => {
  dialogError.textContent = '';
  pageName.value = `后台账号 ${snapshot.pages.filter((page) => !page.monitored).length + 1}`;
  pageURL.value = snapshot.pages[0]?.url || '';
  await showWorkbenchDialog(dialog);
  pageName.select();
});
closeButton.addEventListener('click', () => window.smsApi.closePage(snapshot.selectedPageId));
renameButton.addEventListener('click', async () => {
  const selected = snapshot?.pages.find((page) => page.id === snapshot.selectedPageId);
  if (!selected || selected.monitored) return;
  const name = window.prompt('页面名称', selected.name);
  if (name == null) return;
  const result = await window.smsApi.renamePage(selected.id, name);
  if (!result.ok) window.alert(result.message || '页面名称修改失败');
});
findInput.addEventListener('input', () => {
  clearTimeout(findTimer);
  findTimer = setTimeout(() => runFind(true, true), 120);
});
findInput.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') {
    event.preventDefault();
    closeFind();
  } else if (event.key === 'Enter') {
    event.preventDefault();
    clearTimeout(findTimer);
    runFind(!event.shiftKey, false);
  }
});
findPreviousButton.addEventListener('click', () => runFind(false, false));
findNextButton.addEventListener('click', () => runFind(true, false));
document.querySelector('#find-close').addEventListener('click', closeFind);
document.addEventListener('keydown', (event) => {
  if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'f') {
    event.preventDefault();
    openFind();
  }
});

for (const id of ['cancel-add', 'cancel-add-bottom']) {
  document.querySelector(`#${id}`).addEventListener('click', () => dialog.close());
}
for (const id of ['cancel-credentials', 'cancel-credentials-bottom']) {
  document.querySelector(`#${id}`).addEventListener('click', () => credentialsDialog.close());
}
dialog.addEventListener('close', restoreWorkbenchView);
credentialsDialog.addEventListener('close', restoreWorkbenchView);
document.querySelector('#add-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const result = await window.smsApi.addPage({ name: pageName.value, url: pageURL.value });
  if (!result.ok) {
    dialogError.textContent = result.message;
    return;
  }
  dialog.close();
});

document.querySelector('#credentials-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const result = await window.smsApi.saveCredentials(credentialModuleId, {
    username: credentialUsername.value,
    password: credentialPassword.value,
    totpSecret: credentialTotp.value,
    clearTotp: credentialClearTotp.checked,
    autoLoginEnabled: credentialEnabled.checked
  });
  if (!result.ok) {
    credentialsError.textContent = result.message;
    return;
  }
  credentialsDialog.close();
});

removeCredentialsButton.addEventListener('click', async () => {
  const result = await window.smsApi.removeCredentials(credentialModuleId);
  if (!result.ok) {
    credentialsError.textContent = result.message;
    return;
  }
  credentialsDialog.close();
});

async function initialize() {
  window.smsApi.onShowFind(openFind);
  window.smsApi.onFindResult((result) => {
    if (!snapshot || result.pageId !== snapshot.selectedPageId || findBar.hidden) return;
    const matches = Number(result.matches) || 0;
    const active = matches > 0 ? Number(result.activeMatchOrdinal) || 1 : 0;
    findCount.textContent = `${active}/${matches}`;
    findInput.classList.toggle('not-found', matches === 0 && result.finalUpdate);
    if (result.finalUpdate) {
      findPreviousButton.disabled = matches === 0;
      findNextButton.disabled = matches === 0;
    }
  });
  window.smsApi.onSnapshot((next) => {
    snapshot = next;
    render();
  });
  snapshot = await window.smsApi.getSnapshot();
  render();
}

initialize();
