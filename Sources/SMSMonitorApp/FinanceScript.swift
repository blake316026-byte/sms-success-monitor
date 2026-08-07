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

    const findAmounts = (root, rechargeKey, withdrawKey) => {
      const queue = [root];
      const seen = new Set();
      while (queue.length > 0) {
        const value = queue.shift();
        if (!value || typeof value !== 'object' || seen.has(value)) continue;
        seen.add(value);

        const rechargeAmount = Number(value[rechargeKey]);
        const withdrawAmount = Number(value[withdrawKey]);
        if (Number.isFinite(rechargeAmount) && Number.isFinite(withdrawAmount)) {
          return { rechargeAmount, withdrawAmount };
        }

        for (const child of Array.isArray(value) ? value : Object.values(value)) {
          if (child && typeof child === 'object') queue.push(child);
        }
      }
      return null;
    };

    const user = readStoredValue('lt-user');
    const pageToken = String(user && typeof user === 'object' ? user.token || '' : '').trim();
    const savedToken = String(fallbackToken || '').trim();
    const token = pageToken || savedToken;
    if (!token) {
      return { kind: 'auth', message: '客户端登录态已失效，请重新登录。' };
    }

    const urlCache = readUrlCache();
    const country = String(urlCache.COUNTRY || readStoredValue('COUNTRY') || 'PH');
    const language = String(readStoredValue('locale') || 'zh-cn');
    const tkk = urlCache.Tkk || readStoredValue('Tkk');
    const headers = {
      Accept: 'application/json',
      'Content-Type': 'application/json; charset=utf-8',
      Auth: token,
      COUNTRY: country,
      LANGUAGE: language
    };
    if (tkk) headers.Tkk = String(tkk);

    const dashboardEndpoint = new URL('/api/dashboard4bix/realtime', window.location.origin).href;
    const okbetEndpoint = new URL('/api/realtime_record/with_country', window.location.origin).href;

    try {
      const controller = new AbortController();
      const timeout = window.setTimeout(() => controller.abort(), 20000);
      const response = await window.fetch(dashboardEndpoint, {
        method: 'POST', credentials: 'include', headers, body: JSON.stringify({}),
        signal: controller.signal
      });
      window.clearTimeout(timeout);
      if (response.ok) {
        const payload = await response.json();
        if (isSuccessfulPayload(payload)) {
          const metrics = findAmounts(payload, 'rechargeSuccAmount', 'withdrawSuccAmount');
          if (metrics) return { kind: 'ok', dailyFinancial: metrics };
        }
      }
    } catch (_) {}

    try {
      const controller = new AbortController();
      const timeout = window.setTimeout(() => controller.abort(), 20000);
      const response = await window.fetch(okbetEndpoint, {
        method: 'POST', credentials: 'include', headers,
        body: JSON.stringify({ dayOffset: 0, countryId: country }),
        signal: controller.signal
      });
      window.clearTimeout(timeout);
      if (!response.ok) {
        return { kind: 'error', message: `今日统计接口返回 HTTP ${response.status}。` };
      }
      const payload = await response.json();
      if (!isSuccessfulPayload(payload)) {
        return { kind: 'error', message: payload.message || '今日统计接口状态异常。' };
      }
      const metrics = findAmounts(payload, 'rechargeAmount', 'withdrawAmount');
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
    """#
}
