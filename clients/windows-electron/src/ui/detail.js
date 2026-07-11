import { Globe, RefreshCcw, RefreshCw, createIcons } from 'lucide';

const icons = { Globe, RefreshCcw, RefreshCw };
let snapshot;
let selectedId;

function statusLabel(status) {
  return { starting: '等待连接', scanning: '扫描中', healthy: '正常', alert: '报警', auth: '需登录', error: '异常' }[status] || status;
}

function formatTime(value) {
  if (!value) return '--';
  return new Intl.DateTimeFormat('zh-CN', { hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false }).format(new Date(value));
}

function render(next) {
  snapshot = next;
  if (!selectedId || !snapshot.modules.some((module) => module.id === selectedId)) selectedId = snapshot.summary.focusId;
  const scanned = snapshot.summary.alertCount + snapshot.summary.healthyCount;
  document.querySelector('#coverage').textContent = `已扫描 ${scanned}/${snapshot.modules.length} · 阈值低于 50%`;
  document.querySelector('#alert-count').textContent = `报警 ${snapshot.summary.alertCount}`;
  document.querySelector('#healthy-count').textContent = `正常 ${snapshot.summary.healthyCount}`;
  document.querySelector('#auth-count').textContent = `需登录 ${snapshot.summary.authenticationCount}`;
  document.querySelector('#error-count').textContent = `异常 ${snapshot.summary.errorCount}`;

  const body = document.querySelector('#module-rows');
  body.replaceChildren(...snapshot.modules.map((module) => {
    const row = document.createElement('tr');
    row.dataset.status = module.status;
    if (module.id === selectedId) row.classList.add('selected');
    const metrics = module.metrics;
    row.innerHTML = `
      <td class="module-name">${escapeHTML(module.name)}</td>
      <td class="state-cell">${statusLabel(module.status)}</td>
      <td class="rate-cell">${module.percentageText}</td>
      <td>${metrics ? `${metrics.successCount} / ${metrics.sampleCount}` : '-- / --'}</td>
      <td>${metrics ? metrics.nonSuccessCount : '--'}</td>
      <td>${formatTime(module.scannedAt)}</td>`;
    row.addEventListener('click', () => { selectedId = module.id; render(snapshot); });
    row.addEventListener('dblclick', () => window.smsApi.showWorkbench(module.id));
    return row;
  }));
  renderSelected();
  createIcons({ icons, attrs: { 'stroke-width': 2 } });
}

function renderSelected() {
  const module = snapshot.modules.find((item) => item.id === selectedId);
  if (!module) return;
  document.querySelector('#selected-name').textContent = `${module.name} · ${statusLabel(module.status)}`;
  document.querySelector('#selected-name').dataset.status = module.status;
  document.querySelector('#selected-detail').textContent = module.metrics
    ? `成功 ${module.metrics.successCount}/${module.metrics.sampleCount} · 未成功 ${module.metrics.nonSuccessCount} · 下次 ${formatTime(module.nextScanAt)}`
    : module.message;
}

function escapeHTML(value) {
  const span = document.createElement('span');
  span.textContent = value;
  return span.innerHTML;
}

document.querySelector('#scan-all').addEventListener('click', () => window.smsApi.scan(null));
document.querySelector('#scan-selected').addEventListener('click', () => window.smsApi.scan(selectedId));
document.querySelector('#open-selected').addEventListener('click', () => window.smsApi.showWorkbench(selectedId));
async function initialize() {
  window.smsApi.onSnapshot(render);
  render(await window.smsApi.getSnapshot());
}

initialize();
