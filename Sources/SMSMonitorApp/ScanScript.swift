enum ScanScript {
  static let body = #"""
    const requestedLimit = Math.min(500, Math.max(10, Math.round(Number(sampleLimit) || 200)));
    const maximumPages = Math.max(1, Math.ceil(requestedLimit / 20));

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

    const user = readStoredValue('lt-user');
    const token = user && typeof user === 'object' ? user.token : null;
    if (!token) {
      return { kind: 'auth', message: '客户端登录态已失效，请重新登录。' };
    }

    const urlCache = readUrlCache();
    const country = String(urlCache.COUNTRY || readStoredValue('COUNTRY') || 'PH');
    const language = String(readStoredValue('locale') || 'zh-cn');
    const tkk = urlCache.Tkk || readStoredValue('Tkk');
    const endpoint = new URL('/api/sms_record/page', window.location.origin).href;
    const headers = {
      Accept: 'application/json',
      'Content-Type': 'application/json; charset=utf-8',
      Auth: String(token),
      COUNTRY: country,
      LANGUAGE: language
    };
    if (tkk) headers.Tkk = String(tkk);

    const collected = [];
    const seen = new Set();
    let reportedTotal = null;

    for (let pageNo = 1; pageNo <= maximumPages && collected.length < requestedLimit; pageNo += 1) {
      const controller = new AbortController();
      const timeout = window.setTimeout(() => controller.abort(), 20000);
      let response;
      try {
        response = await window.fetch(endpoint, {
          method: 'POST',
          credentials: 'include',
          headers,
          body: JSON.stringify({ query: { pageNo, pageSize: requestedLimit } }),
          signal: controller.signal
        });
      } catch (error) {
        window.clearTimeout(timeout);
        return {
          kind: 'error',
          message: error && error.name === 'AbortError' ? '请求超过 20 秒。' : '无法连接短信记录接口。'
        };
      }
      window.clearTimeout(timeout);

      if (response.status === 401 || response.status === 403) {
        return { kind: 'auth', message: `平台返回 HTTP ${response.status}，请重新登录。` };
      }
      if (!response.ok) {
        return { kind: 'error', message: `短信记录接口返回 HTTP ${response.status}。` };
      }

      let payload;
      try {
        payload = await response.json();
      } catch (_) {
        return { kind: 'error', message: '短信记录接口没有返回有效 JSON。' };
      }

      const apiStatus = Number(payload && payload.status);
      if (apiStatus !== 0) {
        if ([1010, 1011, 1012, 1013, 1014].includes(apiStatus)) {
          return { kind: 'auth', message: payload.message || `登录状态异常 (${apiStatus})。` };
        }
        return { kind: 'error', message: payload.message || `短信记录接口状态异常 (${apiStatus})。` };
      }

      const page = payload.page || {};
      const rows = Array.isArray(page.content) ? page.content : [];
      if (reportedTotal == null) {
        const parsedTotal = Number(page.totalElements);
        reportedTotal = Number.isFinite(parsedTotal) ? parsedTotal : rows.length;
      }

      for (let index = 0; index < rows.length && collected.length < requestedLimit; index += 1) {
        const row = rows[index] || {};
        const dedupeKey = row.id != null
          ? `id:${row.id}`
          : `row:${row.phone || ''}|${row.code || ''}|${row.createTime || ''}|${row.status || ''}`;
        if (seen.has(dedupeKey)) continue;
        seen.add(dedupeKey);
        collected.push(String(row.status || ''));
      }

      if (rows.length === 0 || collected.length >= requestedLimit || collected.length >= reportedTotal) {
        break;
      }
    }

    return {
      kind: 'ok',
      statuses: collected,
      reportedTotal: reportedTotal == null ? collected.length : reportedTotal
    };
    """#
}
