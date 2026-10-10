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

    const readStoredUsers = () => {
      const users = [];
      const identities = new Set();
      const snapshot = [];
      for (const [storeName, store] of [['session', window.sessionStorage], ['local', window.localStorage]]) {
        for (let index = 0; index < store.length; index += 1) {
          const key = store.key(index);
          if (!key || (key !== 'lt-user' && !key.endsWith('-lt-user'))) continue;
          const raw = store.getItem(key);
          snapshot.push([storeName, key, raw]);
          let value;
          try { value = JSON.parse(raw); } catch (_) { value = null; }
          if (!value || typeof value !== 'object') continue;
          const identity = String(value.username || value.account || value.loginName || value.id || '').trim();
          if (identity) identities.add(identity);
          users.push(value);
        }
      }
      snapshot.sort((left, right) => `${left[0]}:${left[1]}`.localeCompare(`${right[0]}:${right[1]}`));
      return { users, identities: [...identities], accountConflict: identities.size > 1, snapshot: JSON.stringify(snapshot) };
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
    const usernameOf = (value) => String(
      value && typeof value === 'object'
        ? value.username || value.account || value.loginName || ''
        : ''
    ).trim();
    const storedUsers = readStoredUsers();
    const user = storedUsers.users[0] ?? null;
    const signedOut = () => window.__smsMonitorSignedOut === true
      || window.localStorage.getItem('__smsMonitorSignedOut') === '1';
    const sessionUsername = storedUsers.accountConflict ? '' : signedOut()
      ? String(window.localStorage.getItem('__smsMonitorSignedOutUsername') || '').trim()
      : (storedUsers.identities[0] || usernameOf(user));
    if (signedOut()) return { kind: 'auth', manualOnly: true, sessionUsername, message: '已退出账号，不再使用旧 Token。' };
    if (storedUsers.accountConflict) {
      return { kind: 'auth', manualOnly: true, sessionUsername, message: '检测到多个账号的页面会话，请人工确认登录账号。' };
    }
    const tokenCandidates = storedUsers.users
      .map((candidate) => String(candidate.token || '').trim())
      .filter((token, index, tokens) => token && tokens.indexOf(token) === index);
    if (tokenCandidates.length === 0) {
      return { kind: 'auth', manualOnly: false, sessionUsername, message: '页面登录态已失效，请重新登录。' };
    }
    const initialSession = storedUsers.snapshot;
    const sessionChanged = () => signedOut() || readStoredUsers().snapshot !== initialSession
      || country !== String(readUrlCache().COUNTRY || readStoredValue('COUNTRY') || (isOKBET ? 'PH' : '')).trim().toUpperCase();

    const urlCache = readUrlCache();
    const language = String(readStoredValue('locale') || 'zh-cn');
    const tkk = urlCache.Tkk || readStoredValue('Tkk');
    const normalizedPlatformID = String(platformID || '').trim().toLowerCase();
    const normalizedPlatformName = String(platformName || '').trim().toLowerCase();
    const isOKBET = normalizedPlatformID === 'ok01'
      || normalizedPlatformName === 'okbet'
      || normalizedPlatformName === 'ok01';
    const country = String(urlCache.COUNTRY || readStoredValue('COUNTRY')
      || (isOKBET ? 'PH' : '')).trim().toUpperCase();

    // Match the two payment-record summary controls, not the report dashboard.
    const permissionUsers = storedUsers.users.filter((candidate) => Array.isArray(candidate.resources) || typeof candidate.root === 'boolean');
    if (!isOKBET && permissionUsers.length > 0) {
      const allowed = (resource) => permissionUsers.every((candidate) => candidate.root === true || (Array.isArray(candidate.resources) && candidate.resources.some((grant) => (
        typeof grant === 'string' && (grant === resource
          || (grant.endsWith('_') && resource.startsWith(grant)))
      ))));
      if (!allowed('RECHARGE_RECORD_SUMMARY') || !allowed('WITHDRAW_RECORD_SUMMARY')) {
        return { kind: 'permission', message: '当前账号未授权充值或提现记录汇总，已停止财务查询。' };
      }
    }
    if (!/^[A-Z]{2,3}$/.test(country)) {
      return { kind: 'error', message: '无法确认当前选择的国家，已停止财务汇总。' };
    }
    const isAuthenticationFailure = (response, payload) => {
      if (response.status === 401) return true;
      const status = Number(payload && (payload.status ?? payload.code));
      return [1010, 1011, 1012, 1013, 1014].includes(status);
    };

    // Resolve calendar boundaries in the platform's country timezone, never the host timezone.
    const countryDayRange = (timeZone, now) => {
      const formatter = new Intl.DateTimeFormat('en-CA', {
        timeZone, calendar: 'gregory', numberingSystem: 'latn',
        year: 'numeric', month: '2-digit', day: '2-digit'
      });
      const dayKey = (timestamp) => {
        const parts = Object.fromEntries(formatter.formatToParts(new Date(timestamp)).map(part => [part.type, part.value]));
        return Date.UTC(Number(parts.year), Number(parts.month) - 1, Number(parts.day)) / 86400000;
      };
      const today = dayKey(now);
      // Find the first instant of each date, including midnight/DST transitions.
      const boundary = (day) => {
        let low = day * 86400000 - 36 * 3600000;
        let high = day * 86400000 + 36 * 3600000;
        while (low < high) {
          const middle = Math.floor((low + high) / 2);
          if (dayKey(middle) < day) low = middle + 1;
          else high = middle;
        }
        return low;
      };
      return {
        date: new Date(today * 86400000).toISOString().slice(0, 10),
        start: boundary(today), finish: boundary(today + 1) - 1
      };
    };

    let lastHTTPStatus = 0;
    let lastAuthCode = 0;
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

     const amounts = {};
      const cachedZone = window.__smsMonitorCountryTimezones?.[country];
      let timeZone = !isOKBET && cachedZone?.session === initialSession && cachedZone.expires > Date.now()
        ? cachedZone.timeZone : null;
      let queryRange = null;
      const requests = isOKBET
        ? [{ path: '/api/realtime_record/with_country', body: { dayOffset: 0, countryId: country } }]
        : [
            ...(!timeZone ? [{ path: '/api/auth/timezone_with_country', body: { countryId: country }, timezone: true }] : []),
            { path: '/api/recharge_record/summary_query', field: 'rechargeAmount' },
            { path: '/api/withdraw_record/summary_query', field: 'withdrawAmount' }
          ];
     let expired = false;
      for (const request of requests) {
       try {
          if (request.field) {
            queryRange ??= countryDayRange(timeZone, Date.now());
            request.body = { status: 'PAID', dtCreated: { start: queryRange.start, finish: queryRange.finish } };
          }
         const controller = new AbortController();
          const timeout = window.setTimeout(() => controller.abort(), 20000);
          let response;
          try {
            response = await window.fetch(new URL(request.path, window.location.origin).href, {
              method: 'POST', credentials: 'include', headers,
              body: JSON.stringify(request.body), signal: controller.signal
            });
          } finally {
            window.clearTimeout(timeout);
          }
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
          if (isAuthenticationFailure(response, payload)) {
            lastHTTPStatus = response.status;
            lastAuthCode = Number(payload?.status ?? payload?.code) || 0;
            if (response.status !== 401 && lastAuthCode !== 1012) {
              return { kind: 'auth', manualOnly: false, sessionUsername,
                httpStatus: lastHTTPStatus, authCode: lastAuthCode,
                message: payload?.message || `平台要求补充验证 (${lastAuthCode})。` };
            }
            expired = true;
            break;
          }
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
          if (request.timezone) {
            if (typeof payload?.model !== 'string' || !payload.model.trim()) {
              return { kind: 'error', message: '无法确认后台国家时区，已停止今日金额查询。' };
            }
            timeZone = payload.model.trim();
            try { new Intl.DateTimeFormat('en', { timeZone }).format(); }
            catch (_) { return { kind: 'error', message: '后台返回了无效时区，已停止今日金额查询。' }; }
            window.__smsMonitorCountryTimezones ??= {};
            window.__smsMonitorCountryTimezones[country] = {
              timeZone, session: initialSession, expires: Date.now() + 300000
            };
            continue;
          }
          if (isOKBET) {
            const metrics = readOKBETTodayAmounts(payload, country);
            if (!metrics) return { kind: 'error', message: '今日统计接口缺少充值或提现金额。' };
            Object.assign(amounts, metrics);
          } else {
            if (payload?.total == null || payload.total === '') {
              return { kind: 'error', message: '充值或提现记录汇总缺少总金额。' };
            }
            amounts[request.field] = Number(payload.total);
          }
        } catch (error) {
          return {
            kind: 'error',
            message: error && error.name === 'AbortError' ? '今日统计请求超过 20 秒。' : '无法连接今日统计接口。'
          };
        }
      }
      if (expired) continue;
      if (!Number.isFinite(amounts.rechargeAmount) || !Number.isFinite(amounts.withdrawAmount)) {
        return { kind: 'error', message: '今日统计接口缺少充值或提现金额。' };
      }
      return { kind: 'ok', dailyFinancial: { countryId: country, ...amounts },
        queryContext: isOKBET ? null : { countryId: country, timeZone, status: 'PAID', ...queryRange } };
    }
    return { kind: 'auth', manualOnly: false, sessionUsername,
      httpStatus: lastHTTPStatus, authCode: lastAuthCode, message: '今日统计登录态已失效，请重新登录。' };
    """#
}
