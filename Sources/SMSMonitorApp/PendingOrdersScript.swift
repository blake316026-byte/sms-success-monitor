enum PendingOrdersScript {
  static let context = #"""
    const read = (store, key) => { const v = store.getItem(key); try { return JSON.parse(v); } catch (_) { return v; } };
    const text = v => typeof v === 'string' ? v.trim() : '';
    const ss = window.sessionStorage, ls = window.localStorage;
    const visible = e => e && e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden';
    const fail = message => { throw new Error(message); };
    const fingerprint = async value => [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)))].map(b=>b.toString(16).padStart(2,'0')).join('');
    const capture = () => {
      const merchants = read(ss, 'merchants');
      if (Array.isArray(merchants)) {
        const merchant = text(read(ss, 'merchantPathName')?.[location.pathname.split('/').pop()]) || text(read(ss, 'merchantParam'));
        const username = text(read(ss, 'user')?.operatorName);
        const token = text(read(ls, 'TOKEN'));
        if (!(ss.getItem('tabIsLogin') === '1' || ss.getItem('isLogin') === '1')
          || !token || token !== (text(read(ss, 'token')) || text(read(ss, 'TOKEN')))
          || !username || (expectedUsername && username !== expectedUsername)
          || (text(read(ls, 'OPERATOR_NAME')) && text(read(ls, 'OPERATOR_NAME')) !== username)
          || visible(document.querySelector('.admin-login')) || location.pathname === '/') fail('需登录或完成页面验证');
        if (!merchant || !merchants.some(m => m.merchantCode === merchant)) fail('商户未就绪');
        return { family: 'TC', username, token, merchant, country: '', origin: location.origin,
          timezone: text(read(ls, 'operatorCustomization')?.customTimezone),
          environment: text(read(ss, 'environment')), platform: text(read(ss, 'platform')),
          permission: ss.getItem('permission') };
      }
      if (!allowNPG) fail('暂不支持此平台或页面尚未加载');
      if (window.__smsMonitorSignedOut || ls.getItem('__smsMonitorSignedOut') === '1'
        || ['/login', '/ga-auth', '/unlock-ip', '/'].includes(location.pathname)) fail('需登录或完成页面验证');
      const stored = suffix => {
        const values = [];
        for (const store of [ss, ls]) for (let i = 0; i < store.length; i++) {
          const k = store.key(i); if (k === suffix || k?.endsWith('-' + suffix)) values.push(read(store, k));
        }
        return values;
      };
      const users = stored('lt-user').filter(u => u && typeof u === 'object');
      const usernames = [...new Set(users.map(u => text(u.username || u.account || u.loginName || u.id)).filter(Boolean))];
      const tokens = [...new Set(users.map(u => text(u.token)).filter(Boolean))];
      if (usernames.length !== 1 || tokens.length !== 1 || (expectedUsername && usernames[0] !== expectedUsername)) fail('需登录或账号会话不一致');
      const permission = typeof requiredNPGPermission === 'string' ? requiredNPGPermission : 'WITHDRAW_RECORD_LIST';
      if (users.some(u => (typeof u.root === 'boolean' || Array.isArray(u.resources)) && u.root !== true
        && !u.resources?.some(r => r === permission || (typeof r === 'string' && r.endsWith('_') && permission.startsWith(r))))) fail('无提现记录查询权限');
      let cache = {};
      try { const cc = new URLSearchParams(location.hash.slice(1)).get('CC'); if (cc) cache = JSON.parse(atob(cc.replace(/-/g, '+').replace(/_/g, '/'))); } catch (_) {}
      const country = text(cache.COUNTRY || stored('COUNTRY')[0]).toUpperCase();
      if (!/^[A-Z]{2,3}$/.test(country)) fail('国家未就绪');
      return { family: 'NPG', username: usernames[0], token: tokens[0], country, merchant: '', origin: location.origin,
        tkk: cache.Tkk || stored('Tkk')[0] || '', language: stored('locale')[0] || 'zh-cn', users: JSON.stringify(users) };
    };
    """#

  static let query = context + #"""
    const run = requestID;
    window.__smsPendingOrdersAbort?.abort();
    window.__smsPendingOrdersRun = run;
    const orders = new Map(), warnings = [];
    let current;
    try {
      current = capture();
      const snapshot = JSON.stringify(current);
      const unchanged = () => window.__smsPendingOrdersRun === run && JSON.stringify(capture()) === snapshot;
      const check = () => { if (!unchanged()) fail('会话或查询已变化，请刷新'); };
      const request = async (path, params, method = 'GET') => {
        check();
        const url = new URL(path, location.origin);
        const headers = current.family === 'TC'
          ? { Accept: 'application/json', Authorization: current.token, Merchant: current.merchant,
              merchantCode: current.merchant, platform: current.platform, environment: current.environment,
              customTimezone: current.timezone, Language: text(read(ls, 'language')) || 'zh_CN' }
          : { Accept: 'application/json', 'Content-Type': 'application/json', Auth: current.token,
              COUNTRY: current.country, LANGUAGE: current.language, ...(current.tkk ? { Tkk: String(current.tkk) } : {}) };
        if (method === 'GET') url.search = new URLSearchParams(params).toString();
        const controller = new AbortController();
        window.__smsPendingOrdersAbort = controller;
        const timer = setTimeout(() => controller.abort(), 15000);
        try {
          const r = await fetch(url.href, { method, headers, credentials: 'include', cache: 'no-store',
            signal: controller.signal, ...(method === 'POST' ? { body: JSON.stringify(params) } : {}) });
          check();
          if (r.status === 401) fail('需登录');
          if (r.status === 403) fail('无查询权限');
          if (!r.ok) fail('查询 HTTP ' + r.status);
          const p = await r.json(); check();
          if (current.family === 'TC' ? p?.success !== true : ![0, '0', 'OK', 'SUCCESS'].includes(p?.status ?? p?.code)) fail('接口拒绝查询，请检查登录或权限');
          return p;
        } finally {
          clearTimeout(timer);
          if (window.__smsPendingOrdersAbort === controller) window.__smsPendingOrdersAbort = null;
        }
      };
      if (!/^\d{4}-\d{2}-\d{2}$/.test(startDate) || !/^\d{4}-\d{2}-\d{2}$/.test(endDate) || startDate > endDate) fail('日期范围无效');
      const zone = current.family === 'TC' ? current.timezone : (await request('/api/auth/timezone_with_country', { countryId: current.country }, 'POST')).model;
      if (!zone || typeof zone !== 'string') fail('后台时区未就绪');
      const dayNumber = value => { const t = Date.parse(value + 'T00:00:00Z'); if (!Number.isFinite(t) || new Date(t).toISOString().slice(0, 10) !== value) fail('日期范围无效'); return t / 86400000; };
      const formatter = new Intl.DateTimeFormat('en-CA', { timeZone: zone, year: 'numeric', month: '2-digit', day: '2-digit' });
      const boundary = day => {
        let lo = day * 86400000 - 129600000, hi = day * 86400000 + 129600000;
        while (lo < hi) { const m = Math.floor((lo + hi) / 2); const p = Object.fromEntries(formatter.formatToParts(new Date(m)).map(x => [x.type, x.value]));
          const d = Date.UTC(+p.year, +p.month - 1, +p.day) / 86400000; if (d < day) lo = m + 1; else hi = m; }
        return lo;
      };
      const start = boundary(dayNumber(startDate)), finish = boundary(dayNumber(endDate) + 1) - 1;
      const serverDate = timestamp => {
        const serverZone = ['S1', 'S3'].includes(current.environment) ? 'Etc/GMT+4' : 'Etc/GMT-8';
        const p = Object.fromEntries(new Intl.DateTimeFormat('en-GB', { timeZone: serverZone, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' }).formatToParts(new Date(timestamp)).map(x => [x.type, x.value]));
        return `${p.year}-${p.month}-${p.day} ${p.hour}:${p.minute}:${p.second}`;
      };
      const groups = current.family === 'TC'
        ? [['searchPendingApproval', '待处理', 20011], ['searchPending2ndApproval', '待审核', 20016], ['searchPendingPayment', '支付', 20020]]
        : [['NEW', '待审核'], ['ERROR', '放款异常']];
      const deadline = Date.now() + 90000;
      for (const [status, label, pid] of groups) {
        try {
          const permissions = read(ss, 'permission');
          if (current.family === 'TC' && Array.isArray(permissions) && !permissions.map(Number).includes(pid)) fail('无此页签权限');
          let fetched = 0, lastPage = '', done = false;
          for (let pageNo = 1; pageNo <= 50; pageNo++) {
            if (Date.now() > deadline) fail('查询超时，结果不完整');
            const params = current.family === 'TC'
              ? { merchantCode: current.merchant, startDate: serverDate(start), endDate: serverDate(finish), searchDateMode: 'requestTime', paymentStatus: 'ALL', pageNo, pageSize: 50, pid }
              : { query: { status, pageNo, pageSize: 50, dtCreated: { start, finish } } };
            const p = current.family === 'TC'
              ? await request('/tac/api/relay/get/mcs-v3-player-withdraw-' + status, params)
              : await request('/api/withdraw_record/page', params, 'POST');
            const rows = current.family === 'TC' ? p.value : p.page?.content;
            const total = current.family === 'TC' ? p.totalPageCount : p.page?.totalElements;
            if (!Array.isArray(rows) || (typeof total !== 'number' && !(typeof total === 'string' && /^\d+$/.test(total)))
              || !Number.isSafeInteger(Number(total)) || Number(total) < 0) fail('分页数据格式异常');
            const signature = JSON.stringify(rows.map(r => r.id));
            if (rows.length && signature === lastPage) fail('分页未前进，结果不完整');
            lastPage = signature; fetched += rows.length;
            for (const row of rows) {
              if ((typeof row.id !== 'string' && !Number.isSafeInteger(row.id)) || !String(row.id).trim()) fail('订单号缺失或精度异常');
              if (current.family === 'NPG' && row.status !== status) fail('接口返回非指定状态');
              if (current.family === 'TC' && row.merchantCode && row.merchantCode !== current.merchant) fail('接口返回其他商户订单');
              if (current.family === 'TC' && ['PAID', 'REJECT', 'REJECT_PAID', 'CANCELLED'].includes(row.status)) fail('待处理接口返回已结束订单');
              orders.set(String(row.id), { id: String(row.id), status: label, rawStatus: String(row.status || status) });
            }
            if (fetched >= Number(total)) { done = true; break; }
            if (!rows.length) fail('订单数量变化，请刷新核对');
          }
          if (!done) fail('超过 2500 条上限，请缩小日期范围');
        } catch (e) { check(); warnings.push(label + '：' + (e.name === 'AbortError' ? '请求超时' : e.message)); }
      }
      check();
      window.__smsPendingOrdersContext = { id: run, snapshot, startDate, endDate };
      return { kind: warnings.length ? 'partial' : 'ok', message: warnings.join('；'), orders: [...orders.values()],
        family: current.family, country: current.country, merchant: current.merchant, contextID: run };
    } catch (e) { return { kind: 'error', message: e.name === 'AbortError' ? '请求超时' : e.message, orders: [] }; }
    """#

  static let validate = context + #"""
    try {
      const isReviewer = typeof reviewerQuery !== 'undefined' && reviewerQuery;
      const saved = isReviewer ? (window.__smsReviewerContext || read(ss, '__smsReviewerContext')) : window.__smsPendingOrdersContext;
      const current = capture();
      if (!saved) fail('原页面已重新加载，请刷新订单后重试');
      if (saved.id !== contextID) fail('订单列表已更新，请刷新订单后重试');
      if (saved.fingerprint ? saved.fingerprint !== await fingerprint(JSON.stringify(current)) : saved.snapshot !== JSON.stringify(current)) fail('账号、国家或商户已变化，请刷新订单后重试');
      return { kind: 'ok', origin: current.origin, family: current.family, username: current.username, country: current.country, merchant: current.merchant };
    } catch (e) { return { kind: 'error', message: e.message }; }
    """#
}
