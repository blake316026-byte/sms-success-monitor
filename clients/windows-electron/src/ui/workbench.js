import {
  CircleCheck,
  ChevronLeft,
  ChevronRight,
  FileText,
  KeyRound,
  Lock,
  LockKeyhole,
  LoaderCircle,
  Plus,
  Radar,
  RefreshCw,
  TableProperties,
  TriangleAlert,
  WifiOff,
  X,
  createIcons
} from 'lucide';

const iconSet = {
  CircleCheck,
  ChevronLeft,
  ChevronRight,
  FileText,
  KeyRound,
  Lock,
  LockKeyhole,
  LoaderCircle,
  Plus,
  Radar,
  RefreshCw,
  TableProperties,
  TriangleAlert,
  WifiOff,
  X
};
let snapshot;

const tabs = document.querySelector('#tabs');
const address = document.querySelector('#address');
const backButton = document.querySelector('#back');
const forwardButton = document.querySelector('#forward');
const reloadButton = document.querySelector('#reload');
const closeButton = document.querySelector('#close-page');
const credentialsButton = document.querySelector('#credentials');
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
  if (selected) {
    address.value = selected.currentURL;
    backButton.disabled = !selected.canGoBack;
    forwardButton.disabled = !selected.canGoForward;
    closeButton.disabled = selected.monitored;
    credentialsButton.disabled = !selected.monitored;
    reloadButton.classList.toggle('loading', selected.loading);
  }
  createIcons({ icons: iconSet, attrs: { 'stroke-width': 2 } });
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
document.querySelector('#scan').addEventListener('click', () => {
  const selected = snapshot?.pages.find((page) => page.id === snapshot.selectedPageId);
  window.smsApi.scan(selected?.monitored ? selected.id : null);
});
document.querySelector('#detail').addEventListener('click', () => window.smsApi.showDetail());
credentialsButton.addEventListener('click', async () => {
  const selected = snapshot?.pages.find((page) => page.id === snapshot.selectedPageId);
  if (!selected?.monitored) return;
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
  credentialsDialog.showModal();
  credentialUsername.focus();
});
document.querySelector('#add').addEventListener('click', () => {
  dialogError.textContent = '';
  pageName.value = `后台账号 ${snapshot.pages.filter((page) => !page.monitored).length + 1}`;
  pageURL.value = snapshot.pages[0]?.url || '';
  dialog.showModal();
  pageName.select();
});
closeButton.addEventListener('click', () => window.smsApi.closePage(snapshot.selectedPageId));

for (const id of ['cancel-add', 'cancel-add-bottom']) {
  document.querySelector(`#${id}`).addEventListener('click', () => dialog.close());
}
for (const id of ['cancel-credentials', 'cancel-credentials-bottom']) {
  document.querySelector(`#${id}`).addEventListener('click', () => credentialsDialog.close());
}
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
  window.smsApi.onSnapshot((next) => {
    snapshot = next;
    render();
  });
  snapshot = await window.smsApi.getSnapshot();
  render();
}

initialize();
