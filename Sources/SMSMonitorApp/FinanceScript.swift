enum FinanceScript {
  static let body = #"""
    const readStoredValue = (suffix) => {
      const candidates = [];
      const identities = new Set();
      for (const store of [window.sessionStorage, window.localStorage]) {
        for (let index = 0; index < store.length; index += 1) {
          const key = store.key(index);
          if (!key || (key !== suffix && !key.endsWith(`-${suffix}`))) continue;
          const raw = store.getItem(key);
          if (raw == null) continue;
          let value;
          try { value = JSON.parse(raw); } catch (_) { value = raw; }
          if (suffix !== 'lt-user') return value;
          if (value && typeof value === 'object') {
            const identity = String(value.username || value.account || value.loginName || value.id || '').trim();
            if (identity) identities.add(identity);
          }
          candidates.push(value);
        }
      }
      if (identities.size > 1) return { accountConflict: true };
      return candidates.find((value) => value && typeof value === 'object' && value.token)
        ?? candidates[0]
        ?? null;
    };

    const readUrlCache = () => {
      try {
        const fragment = window.location.hash.replace(/^#/, '');
        const encoded = new URLSearchParams(fragment).get('CC');
        if (!encoded) return {};
        const normalized = decodeURIComponent(encoded).replace(/-/g, '+').replace(/_/g, '/');
        const padded = normalized + '='.repeat((4 - (normalized.length % 4)) % 4);
        return JSON.parse(window.atob(padded));
      } catch (_) {
        return {};
      }
    };

    const isSuccessfulPayload = (payload) => {
      const rawStatus = payload && (
        payload.status ?? payload.code ?? payload.statusCode ?? payload.resultCode
      );
      if (rawStatus == null) return true;
      if (Number(rawStatus) === 0) return true;
      return ['OK', 'SUCCESS'].includes(String(rawStatus).trim().toUpperCase());
    };

    const readOKBETTodayAmounts = (payload, countryId) => {
      const rows = Array.isArray(payload && payload.list) ? payload.list : [];
      const row = rows.find((candidate) => (
        candidate
        && String(candidate.countryId || '').toUpperCase() === String(countryId).toUpperCase()
        && candidate.type === 'COUNTRY_DAY'
        && candidate.timeType === 'DAY'
        && !candidate.appId
      ));
      const rechargeAmount = Number(row && row.columns && row.columns.rechargeAmount);
      const withdrawAmount = Number(row && row.columns && row.columns.withdrawAmount);
      return Number.isFinite(rechargeAmount) && Number.isFinite(withdrawAmount)
        ? { rechargeAmount, withdrawAmount }
        : null;
    };
    const readDashboardTodayAmounts = (payload) => {
      const candidates = [
        payload && payload.model && payload.model.today,
        payload && payload.data && payload.data.today,
        payload && payload.today
      ];
      for (const candidate of candidates) {
        const rechargeAmount = Number(candidate && candidate.rechargeSuccAmount);
        const withdrawAmount = Number(candidate && candidate.withdrawSuccAmount);
        if (candidate && Number.isFinite(rechargeAmount) && Number.isFinite(withdrawAmount)) {
          return { rechargeAmount, withdrawAmount };
        }
      }
      return null;
    };

    const usernameOf = (value) => String(
      value && typeof value === 'object'
        ? value.username || value.account || value.loginName || ''
        : ''
    ).trim();
    const user = readStoredValue('lt-user');
    const signedOut = () => window.__smsMonitorSignedOut === true
      || window.localStorage.getItem('__smsMonitorSignedOut') === '1';
    const sessionUsername = signedOut()
      ? String(window.localStorage.getItem('__smsMonitorSignedOutUsername') || '').trim()
      : usernameOf(user);
    if (signedOut()) return { kind: 'auth', manualOnly: true, sessionUsername, message: '已退出账号，不再使用旧 Token。' };
    const pageToken = String(user && typeof user === 'object' ? user.token || '' : '').trim();
    const tokenCandidates = [];
    if (pageToken) tokenCandidates.push(pageToken);
    if (tokenCandidates.length === 0) {
      return { kind: 'auth', manualOnly: Boolean(user?.accountConflict), sessionUsername, message: '页面登录态已失效，请重新登录。' };
    }
    const initialSession = JSON.stringify(user);
    const sessionChanged = () => signedOut() || JSON.stringify(readStoredValue('lt-user')) !== initialSession;

    const urlCache = readUrlCache();
    const country = String(urlCache.COUNTRY || readStoredValue('COUNTRY') || 'PH');
    const language = String(readStoredValue('locale') || 'zh-cn');
    const tkk = urlCache.Tkk || readStoredValue('Tkk');
    const dashboardEndpoint = new URL('/api/dashboard4bix/realtime', window.location.origin).href;
    const okbetEndpoint = new URL('/api/realtime_record/with_country', window.location.origin).href;
    const normalizedPlatformID = String(platformID || '').trim().toLowerCase();
    const normalizedPlatformName = String(platformName || '').trim().toLowerCase();
    const isOKBET = normalizedPlatformID === 'ok01'
      || normalizedPlatformName === 'okbet'
      || normalizedPlatformName === 'ok01';

    // NPG's report menu requires REPORT and CK_DASHBOARD, not payment summaries.
    if (!isOKBET && user && (Array.isArray(user.resources) || typeof user.root === 'boolean')) {
      const allowed = (resource) => user.root === true || (Array.isArray(user.resources) && user.resources.some((grant) => (
        typeof grant === 'string' && (grant === resource
          || (grant.endsWith('_') && resource.startsWith(grant)))
      )));
      if (!allowed('REPORT') || !allowed('CK_DASHBOARD')) {
        return { kind: 'permission', message: '当前账号未授权报表看板（REPORT / CK_DASHBOARD），已停止财务查询。' };
      }
    }
    const isAuthenticationFailure = (response, payload) => {
      if (response.status === 401) return true;
      const status = Number(payload && (payload.status ?? payload.code));
      return [1010, 1011, 1012, 1013, 1014].includes(status);
    };

    for (const token of tokenCandidates) {
      const headers = {
        Accept: 'application/json',
        'Content-Type': 'application/json; charset=utf-8',
        Auth: token,
        COUNTRY: country,
        LANGUAGE: language
      };
      if (tkk) headers.Tkk = String(tkk);
      if (isOKBET && country.toUpperCase() === 'PH') headers.SYSTIMEZONE = 'Asia/Manila';

      try {
        const controller = new AbortController();
        const timeout = window.setTimeout(() => controller.abort(), 20000);
        const response = await window.fetch(isOKBET ? okbetEndpoint : dashboardEndpoint, {
          method: 'POST', credentials: 'include', headers,
          body: JSON.stringify(isOKBET ? { dayOffset: 0, countryId: country } : {}),
          signal: controller.signal
        });
        window.clearTimeout(timeout);
        if (sessionChanged()) return { kind: 'sessionChanged' };
        let payload = null;
        try {
          payload = await response.json();
        } catch (_) {}
        if (sessionChanged()) return { kind: 'sessionChanged' };
        if (response.status === 403 || Number(payload?.status ?? payload?.code) === 403
          || /无权限|没有权限|权限不足|拒绝访问|forbidden|permission|access denied|unauthorized/i.test(String(payload?.message || ''))) {
          return { kind: 'permission', message: '当前账号无财务数据查看权限，已停止财务查询。' };
        }
        if (isAuthenticationFailure(response, payload)) continue;
        if (!response.ok) {
          return { kind: 'error', message: `今日统计接口返回 HTTP ${response.status}。` };
        }
        if (!isSuccessfulPayload(payload)) {
          const message = String(payload && payload.message || '');
          if (/无权限|没有权限|forbidden|permission|unauthorized/i.test(message)) {
            return { kind: 'permission', message: '当前账号无财务数据查看权限，已停止财务查询。' };
          }
          return { kind: 'error', message: payload && payload.message || '今日统计接口状态异常。' };
        }
        const metrics = isOKBET
          ? readOKBETTodayAmounts(payload, country)
          : readDashboardTodayAmounts(payload);
        if (!metrics) {
          return { kind: 'error', message: '今日统计接口缺少充值或提现金额。' };
        }
        return { kind: 'ok', dailyFinancial: metrics };
      } catch (error) {
        return {
          kind: 'error',
          message: error && error.name === 'AbortError' ? '今日统计请求超过 20 秒。' : '无法连接今日统计接口。'
        };
      }
    }
    return { kind: 'auth', manualOnly: false, sessionUsername, message: '今日统计登录态已失效，请重新登录。' };
    """#
}
