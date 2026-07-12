import {
  CheckCircle,
  Clock,
  Lock,
  RadioTower,
  RefreshCw,
  TriangleAlert,
  WifiOff,
  createIcons
} from 'lucide';

const icons = { CheckCircle, Clock, Lock, RadioTower, RefreshCw, TriangleAlert, WifiOff };
const root = document.querySelector('#widget');
const name = document.querySelector('#widget-name');
const badge = document.querySelector('#widget-badge');
const value = document.querySelector('#widget-value');
const sample = document.querySelector('#widget-sample');
const footer = document.querySelector('#widget-footer-text');
const footerIcon = document.querySelector('#widget-footer-icon');

function render(snapshot) {
  const focus = snapshot.modules.find((module) => module.id === snapshot.summary.focusId);
  if (!focus) return;
  const status = presentation(focus, snapshot.summary, snapshot.sampleLimit);
  name.textContent = focus.name;
  badge.textContent = status.badge;
  value.textContent = status.value;
  sample.textContent = status.sample;
  footer.textContent = status.footer;
  footerIcon.dataset.lucide = status.icon;
  root.dataset.status = status.kind;
  root.style.setProperty('--status-color', status.color);
  root.style.setProperty('--progress', `${Math.max(0, Math.min(1, focus.metrics?.successRate || 0)) * 360}deg`);
  createIcons({ icons, attrs: { 'stroke-width': 2.2 } });
}

function presentation(focus, summary, sampleLimit) {
  const rate = focus.percentageText || '--';
  const metrics = focus.metrics;
  if (focus.status === 'alert') {
    return {
      kind: 'alert', color: '#ff3953', badge: summary.alertCount > 1 ? `报警 ${summary.alertCount}` : '报警',
      value: rate, sample: `样本 ${metrics.sampleCount}`, footer: `最低 · 成功 ${metrics.successCount}/${metrics.sampleCount}`,
      icon: 'triangle-alert'
    };
  }
  if (focus.status === 'healthy') {
    return {
      kind: 'healthy', color: '#20cf73', badge: '正常', value: rate, sample: `样本 ${metrics.sampleCount}`,
      footer: `成功 ${metrics.successCount} · 未成功 ${metrics.nonSuccessCount}`, icon: 'check-circle'
    };
  }
  if (focus.status === 'scanning') {
    return {
      kind: 'scanning', color: '#4599ff', badge: '扫描中', value: metrics ? rate : '扫描中',
      sample: metrics ? `样本 ${metrics.sampleCount}` : `读取最新 ${sampleLimit} 条`, footer: '正在更新监控数据', icon: 'refresh-cw'
    };
  }
  if (focus.status === 'auth') {
    return {
      kind: 'auth', color: '#ffb22e', badge: summary.authenticationCount > 1 ? `待登录 ${summary.authenticationCount}` : '需登录',
      value: '需登录', sample: '打开平台窗口', footer: '点击查看详情并重新登录', icon: 'lock'
    };
  }
  if (focus.status === 'error') {
    return {
      kind: 'error', color: '#7d8999', badge: '异常', value: '连接异常', sample: '查看监控总览',
      footer: '等待下一次自动重试', icon: 'wifi-off'
    };
  }
  return {
    kind: 'starting', color: '#7d8999', badge: '启动中', value: '启动中', sample: '等待首次扫描',
    footer: '正在建立连接', icon: 'clock'
  };
}

for (const id of ['open-detail', 'open-detail-footer']) {
  document.querySelector(`#${id}`).addEventListener('click', () => window.smsApi.showDetail());
}
document.addEventListener('contextmenu', (event) => {
  event.preventDefault();
  window.smsApi.showWidgetMenu();
});

async function initialize() {
  window.smsApi.onSnapshot(render);
  render(await window.smsApi.getSnapshot());
}

initialize();
