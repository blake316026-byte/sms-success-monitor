globalThis.smsMonitorFinance = async function smsMonitorFinance(platformID, platformName, fallbackToken = '') {
  const readStoredValue = (suffix) => {
    let found = null;
    const identities = new Set();
    for (const store of [window.localStorage, window.sessionStorage]) {
      for (let index = 0; index < store.length; index += 1) {
        const key = store.key(index);
        if (!key || (key !== suffix && !key.endsWith(`-${suffix}`))) continue;
        const raw = store.getItem(key);
        if (raw == null) continue;
        let value;
        try { value = JSON.parse(raw); } catch (_) { value = raw; }
        if (suffix !== 'lt-user') return value;
        if (value && typeof value === 'object') {
          identities.add(JSON.stringify([value.token || '', value.username || value.account || value.id || '']));
        }
        if (found == null) found = value;
      }
    }
    if (identities.size > 1) return { accountConflict: true };
    return found;
  };
  const readUrlCache = () => {
    try {
      const encoded = new URLSearchParams(window.location.hash.replace(/^#/, '')).get('CC');
      if (!encoded) return {};
      const normalized = decodeURIComponent(encoded).replace(/-/g, '+').replace(/_/g, '/');
      return JSON.parse(window.atob(normalized + '='.repeat((4 - normalized.length % 4) % 4)));
    } catch (_) { return {}; }
  };
  const pageUser = readStoredValue('lt-user');
  const signedOut = () => window.__smsMonitorSignedOut === true
    || window.localStorage.getItem('__smsMonitorSignedOut') === '1';
  if (signedOut()) return { kind: 'auth', manualOnly: true, message: '已退出账号，不再使用旧 Token。' };
  const pageToken = String(pageUser && typeof pageUser === 'object' ? pageUser.token || '' : '').trim();
  const savedToken = String(fallbackToken || '').trim();
  const tokens = [pageToken || (!pageUser ? savedToken : '')].filter(Boolean);
  if (tokens.length === 0) return { kind: 'auth', manualOnly: Boolean(pageUser), message: '客户端登录态已失效，请重新登录。' };
  const initialSession = JSON.stringify(pageUser);
  const sessionChanged = () => signedOut() || JSON.stringify(readStoredValue('lt-user')) !== initialSession;
  const cache = readUrlCache();
  const country = String(cache.COUNTRY || readStoredValue('COUNTRY') || 'PH');
  const normalizedID = String(platformID || '').trim().toLowerCase();
  const normalizedName = String(platformName || '').trim().toLowerCase();
  const isOKBET = normalizedID === 'ok01' || normalizedName === 'okbet' || normalizedName === 'ok01';

  // NPG's report menu requires REPORT and CK_DASHBOARD, not payment summaries.
  if (!isOKBET && pageUser && (Array.isArray(pageUser.resources) || typeof pageUser.root === 'boolean')) {
    const allowed = (resource) => pageUser.root === true || (Array.isArray(pageUser.resources) && pageUser.resources.some((grant) => (
      typeof grant === 'string' && (grant === resource
        || (grant.endsWith('_') && resource.startsWith(grant)))
    )));
    if (!allowed('REPORT') || !allowed('CK_DASHBOARD')) {
      return { kind: 'permission', message: '当前账号未授权报表看板（REPORT / CK_DASHBOARD），已停止财务查询。' };
    }
  }
  const endpoint = new URL(
    isOKBET ? '/api/realtime_record/with_country' : '/api/dashboard4bix/realtime',
    window.location.origin
  ).href;
  for (const token of tokens) {
    const headers = {
      Accept: 'application/json',
      'Content-Type': 'application/json; charset=utf-8',
      Auth: token,
      COUNTRY: country,
      LANGUAGE: String(readStoredValue('locale') || 'zh-cn')
    };
    if (cache.Tkk || readStoredValue('Tkk')) headers.Tkk = String(cache.Tkk || readStoredValue('Tkk'));
    if (isOKBET) headers.SYSTIMEZONE = 'Asia/Manila';
    try {
      const controller = new AbortController();
      const timeout = window.setTimeout(() => controller.abort(), 20000);
      const response = await window.fetch(endpoint, {
        method: 'POST', credentials: 'include', headers,
        body: JSON.stringify(isOKBET ? { dayOffset: 0, countryId: country } : {}),
        signal: controller.signal
      });
      window.clearTimeout(timeout);
      if (sessionChanged()) return { kind: 'sessionChanged' };
      let payload = null;
      try { payload = await response.json(); } catch (_) {}
      if (sessionChanged()) return { kind: 'sessionChanged' };
      if (response.status === 403 || Number(payload?.status ?? payload?.code) === 403
        || /无权限|没有权限|权限不足|拒绝访问|forbidden|permission|access denied|unauthorized/i.test(String(payload?.message || ''))) {
        return { kind: 'permission', message: '当前账号无财务数据查看权限，已停止财务查询。' };
      }
      if (response.status === 401) continue;
      if (!response.ok) return { kind: 'error', message: `今日统计接口返回 HTTP ${response.status}。` };
      const status = Number(payload && (payload.status ?? payload.code));
      const message = String(payload?.message || '');
      if (/无权限|没有权限|forbidden|permission|unauthorized/i.test(message)) {
        return { kind: 'permission', message: '当前账号无财务数据查看权限，已停止财务查询。' };
      }
      if (Number.isFinite(status) && status !== 0) {
        if ([1010, 1011, 1012, 1013, 1014].includes(status)) continue;
        return { kind: 'error', message: message || `今日统计接口状态异常 (${status})。` };
      }
      let rechargeAmount;
      let withdrawAmount;
      if (isOKBET) {
        const row = (Array.isArray(payload?.list) ? payload.list : []).find((item) =>
          String(item?.countryId || '').toUpperCase() === country.toUpperCase()
          && item?.type === 'COUNTRY_DAY' && item?.timeType === 'DAY' && !item?.appId
        );
        rechargeAmount = Number(row?.columns?.rechargeAmount);
        withdrawAmount = Number(row?.columns?.withdrawAmount);
      } else {
        const today = payload?.model?.today || payload?.data?.today || payload?.today;
        rechargeAmount = Number(today?.rechargeSuccAmount);
        withdrawAmount = Number(today?.withdrawSuccAmount);
      }
      if (!Number.isFinite(rechargeAmount) || !Number.isFinite(withdrawAmount)) {
        return { kind: 'error', message: '今日统计接口缺少充值或提现金额。' };
      }
      return { kind: 'ok', dailyFinancial: { rechargeAmount, withdrawAmount } };
    } catch (error) {
      return { kind: 'error', message: error?.name === 'AbortError' ? '今日统计请求超过 20 秒。' : '无法连接今日统计接口。' };
    }
  }
  return { kind: 'auth', manualOnly: Boolean(pageUser), message: '今日统计登录态已失效，请重新登录。' };
};
