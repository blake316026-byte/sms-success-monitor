enum FinanceScript {
  static let body = #"""
    const readStoredValue = (suffix) => {
      for (const store of [window.localStorage, window.sessionStorage]) {
        for (let index = 0; index < store.length; index += 1) {
          const key = store.key(index);
          if (!key || (key !== suffix && !key.endsWith(`-${suffix}`))) continue;
          const raw = store.getItem(key);
          if (raw == null) continue;
          try {
            return JSON.parse(raw);
          } catch (_) {
            return raw;
          }
        }
      }
      return null;
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

    const user = readStoredValue('lt-user');
    const pageToken = String(user && typeof user === 'object' ? user.token || '' : '').trim();
    const savedToken = String(fallbackToken || '').trim();
    const tokenCandidates = [];
    if (pageToken) tokenCandidates.push(pageToken);
    if (savedToken && savedToken !== pageToken) tokenCandidates.push(savedToken);
    if (tokenCandidates.length === 0) {
      return { kind: 'auth', message: '客户端登录态已失效，请重新登录。' };
    }

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
    const isAuthenticationFailure = (response, payload) => {
      if (response.status === 401 || response.status === 403) return true;
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
        let payload = null;
        try {
          payload = await response.json();
        } catch (_) {}
        if (isAuthenticationFailure(response, payload)) continue;
        if (!response.ok) {
          return { kind: 'error', message: `今日统计接口返回 HTTP ${response.status}。` };
        }
        if (!isSuccessfulPayload(payload)) {
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
    return { kind: 'auth', message: '今日统计登录态已失效，请重新登录。' };
    """#
}
