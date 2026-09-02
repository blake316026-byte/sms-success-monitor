enum ScanScript {
  static let body = #"""
    const requestedLimit = Math.min(500, Math.max(10, Math.round(Number(sampleLimit) || 200)));
    // Leave bounded headroom for duplicate rows at page boundaries so the
    // deduplicated sample can still reach the requested size.
    const maximumPages = Math.max(1, Math.ceil(requestedLimit / 20) + 5);
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    const createdStart = new Date(today);
    createdStart.setDate(createdStart.getDate() - 3);
    const createdFinish = new Date(today);
    createdFinish.setDate(createdFinish.getDate() + 1);
    const createdRange = {
      start: createdStart.getTime(),
      finish: createdFinish.getTime()
    };

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
    const savedToken = String(fallbackToken || '').trim();
    const tokenCandidates = [];
    if (pageToken) tokenCandidates.push({ token: pageToken, source: 'page' });
    if (!user && savedToken) tokenCandidates.push({ token: savedToken, source: 'fallback' });
    if (tokenCandidates.length === 0) {
      return { kind: 'auth', manualOnly: Boolean(user), sessionUsername, message: '客户端登录态已失效，请重新登录。' };
    }
    const initialSession = JSON.stringify(user);
    const sessionChanged = () => signedOut() || JSON.stringify(readStoredValue('lt-user')) !== initialSession;

    // Match the backend's checkAuth rules before issuing a protected query.
    if (user && (Array.isArray(user.resources) || typeof user.root === 'boolean')) {
      const allowed = user.root === true || (Array.isArray(user.resources) && user.resources.some((grant) => (
        typeof grant === 'string' && (grant === 'SMS_RECORD_LIST'
          || (grant.endsWith('_') && 'SMS_RECORD_LIST'.startsWith(grant)))
      )));
      if (!allowed) return { kind: 'permission', message: '当前账号未授权短信记录（SMS_RECORD_LIST），已停止短信查询。' };
    }

    const restorePageSession = (token) => {
      let restored = false;
      for (const store of [window.localStorage, window.sessionStorage]) {
        for (let index = 0; index < store.length; index += 1) {
          const key = store.key(index);
          if (!key || (key !== 'lt-user' && !key.endsWith('-lt-user'))) continue;
          try {
            const storedUser = JSON.parse(store.getItem(key));
            if (!storedUser || typeof storedUser !== 'object') continue;
            storedUser.token = token;
            store.setItem(key, JSON.stringify(storedUser));
            restored = true;
          } catch (_) {}
        }
      }
      if (restored) return true;
      try {
        let prefix = '';
        for (let index = 0; index < window.localStorage.length; index += 1) {
          const key = window.localStorage.key(index) || '';
          const match = key.match(/^(.*)-(?:locale|Tkk|COUNTRY)$/);
          if (match) {
            prefix = match[1];
            break;
          }
        }
        const userKey = prefix ? `${prefix}-lt-user` : 'lt-user';
        window.localStorage.setItem(userKey, JSON.stringify({ token }));
        return true;
      } catch (_) {
        return false;
      }
    };

    const urlCache = readUrlCache();
    const country = String(urlCache.COUNTRY || readStoredValue('COUNTRY') || 'PH');
    const language = String(readStoredValue('locale') || 'zh-cn');
    const tkk = urlCache.Tkk || readStoredValue('Tkk');
    const apiPageSize = 20;
    const endpoint = new URL('/api/sms_record/page', window.location.origin).href;
    const isSuccessfulPayload = (payload) => {
      const rawStatus = payload && (
        payload.status ?? payload.code ?? payload.statusCode ?? payload.resultCode
      );
      if (rawStatus == null) return true;
      if (Number(rawStatus) === 0) return true;
      return ['OK', 'SUCCESS'].includes(String(rawStatus).trim().toUpperCase());
    };
    const findAmounts = (root, rechargeKey, withdrawKey) => {
      const queue = [{ value: root, path: '' }];
      const seen = new Set();
      const candidates = [];
      while (queue.length > 0) {
        const item = queue.shift();
        const value = item && item.value;
        const path = item && item.path || '';
        if (!value || typeof value !== 'object' || seen.has(value)) continue;
        seen.add(value);

        const rechargeAmount = Number(value[rechargeKey]);
        const withdrawAmount = Number(value[withdrawKey]);
        if (Number.isFinite(rechargeAmount) && Number.isFinite(withdrawAmount)) {
          const pathText = path.toLowerCase();
          const dayScore = /(^|[._-])(today|day|country_day|summary|total|record|data|model)([._-]|$)/.test(pathText) ? 1000 : 0;
          const detailPenalty = /(hour|chart|trend|series|statistic|statistics|items|list|rows|content|\[\d+\])/.test(pathText) ? 500 : 0;
          candidates.push({
            rechargeAmount,
            withdrawAmount,
            score: dayScore - detailPenalty + rechargeAmount + withdrawAmount
          });
        }

        if (Array.isArray(value)) {
          value.forEach((child, index) => {
            if (child && typeof child === 'object') queue.push({ value: child, path: `${path}[${index}]` });
          });
        } else {
          for (const [key, child] of Object.entries(value)) {
            if (child && typeof child === 'object') queue.push({ value: child, path: path ? `${path}.${key}` : key });
          }
        }
      }
      candidates.sort((left, right) => right.score - left.score);
      return candidates[0] ? {
        rechargeAmount: candidates[0].rechargeAmount,
        withdrawAmount: candidates[0].withdrawAmount
      } : null;
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
    let lastAuthenticationMessage = '客户端登录态已失效，请重新登录。';
    for (const candidate of tokenCandidates) {
      const headers = {
        Accept: 'application/json',
        'Content-Type': 'application/json; charset=utf-8',
        Auth: candidate.token,
        COUNTRY: country,
        LANGUAGE: language
      };
      if (tkk) headers.Tkk = String(tkk);

      const collected = [];
      const seen = new Set();
      let reportedTotal = null;
      let candidateRejected = false;

      for (let pageNo = 1; pageNo <= maximumPages && collected.length < requestedLimit; pageNo += 1) {
        if (sessionChanged()) return { kind: 'sessionChanged' };
        const controller = new AbortController();
        const timeout = window.setTimeout(() => controller.abort(), 20000);
        let response;
        try {
          response = await window.fetch(endpoint, {
            method: 'POST',
            credentials: 'include',
            headers,
            body: JSON.stringify({
              query: {
                pageNo,
                pageSize: apiPageSize,
                ddCreated: createdRange
              }
            }),
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

        if (sessionChanged()) return { kind: 'sessionChanged' };
        if (response.status === 403) {
          return { kind: 'permission', message: '当前账号无短信记录查看权限，已停止短信查询。' };
        }
        if (response.status === 401) {
          lastAuthenticationMessage = `平台返回 HTTP ${response.status}，请重新登录。`;
          candidateRejected = true;
          break;
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

        if (sessionChanged()) return { kind: 'sessionChanged' };
        if (/无权限|没有权限|权限不足|拒绝访问|forbidden|permission|access denied|unauthorized/i.test(String(payload?.message || ''))
          || Number(payload?.status ?? payload?.code) === 403) {
          return { kind: 'permission', message: '当前账号无短信记录查看权限，已停止短信查询。' };
        }
        const apiStatus = Number(payload && payload.status);
        if (apiStatus !== 0) {
          if ([1010, 1011, 1012, 1013, 1014].includes(apiStatus)) {
            lastAuthenticationMessage = payload.message || `登录状态异常 (${apiStatus})。`;
            candidateRejected = true;
            break;
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

      if (candidateRejected) continue;
      const restoredPageSession = candidate.source === 'fallback'
        ? restorePageSession(candidate.token)
        : false;
      return {
        kind: 'ok',
        statuses: collected,
        reportedTotal: reportedTotal == null ? collected.length : reportedTotal,
        tokenSource: candidate.source,
        restoredPageSession
      };
    }

    return { kind: 'auth', manualOnly: Boolean(user), sessionUsername, message: lastAuthenticationMessage };
    """#
}
