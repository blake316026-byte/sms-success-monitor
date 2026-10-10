enum TianchengFinanceScript {
  static let body = #"""
    const read = (store, key) => {
      const value = store.getItem(key);
      try { return JSON.parse(value); } catch (_) { return value; }
    };
    const text = value => typeof value === 'string' ? value.trim() : '';
    const ss = window.sessionStorage, ls = window.localStorage;
    const context = () => {
      const merchantPaths = read(ss, 'merchantPathName');
      const merchant = text(merchantPaths?.[location.pathname.split('/').pop()]) || text(read(ss, 'merchantParam'));
      const merchants = read(ss, 'merchants');
      const row = Array.isArray(merchants) ? merchants.find(item => item?.merchantCode === merchant) : null;
      const user = read(ss, 'user');
      return {
        token: text(read(ls, 'TOKEN')), pageToken: text(read(ss, 'token')) || text(read(ss, 'TOKEN')),
        loggedIn: ss.getItem('tabIsLogin') === '1' || ss.getItem('isLogin') === '1',
        username: text(user?.operatorName), localUsername: text(read(ls, 'OPERATOR_NAME')),
        merchant, currency: text(row?.merchantCurrency).toUpperCase(),
        timeZone: text(read(ls, 'operatorCustomization')?.customTimezone),
        platform: text(read(ss, 'platform')), environment: text(read(ss, 'environment')),
        permission: ss.getItem('permission'), origin: location.origin
      };
    };
    const loginVisible = () => {
      const root = document.querySelector('.admin-login');
      return Boolean(root && root.getClientRects().length && getComputedStyle(root).visibility !== 'hidden');
    };
    const before = context();
    const snapshot = JSON.stringify(before);
    const stale = () => JSON.stringify(context()) !== snapshot || loginVisible();
    if (!before.loggedIn || !before.token || !before.pageToken || loginVisible() || location.pathname === '/') {
      return { kind: 'auth', message: '天成尚未完成登录，请完成页面验证。' };
    }
    if (before.token !== before.pageToken || !before.username
      || (before.localUsername && before.username !== before.localUsername)
      || (text(expectedUsername) && before.username !== text(expectedUsername))) {
      return { kind: 'auth', message: '天成页面账号或会话不一致，已停止数据查询，请确认当前账号。' };
    }
    if (!before.merchant || !before.currency || !before.timeZone) {
      return { kind: 'error', message: '天成商户、币种或后台时区尚未就绪。' };
    }
    // One currency per country bucket; never use the language flag or GMT offset as a country.
    // The operator confirmed on 2026-10-05 that Tiancheng TLB is PHP at 1:1.
    const country = ({ PHP: 'PH', TLB: 'PH', MXN: 'MX', USD: 'US', BRL: 'BR', VND: 'VN', THB: 'TH',
      INR: 'IN', IDR: 'ID', MYR: 'MY', BDT: 'BD', PKR: 'PK', CNY: 'CN' })[before.currency];
    const countryId = country || 'CURRENCY:' + before.currency;
    const permissions = read(ss, 'permission');
    if (Array.isArray(permissions) && !permissions.map(Number).includes(31711)) {
      return { kind: 'permission', message: '当前天成账号没有平台损益查看权限。' };
    }
    let date;
    try {
      const parts = Object.fromEntries(new Intl.DateTimeFormat('en-CA', {
        timeZone: before.timeZone, calendar: 'gregory', numberingSystem: 'latn',
        year: 'numeric', month: '2-digit', day: '2-digit'
      }).formatToParts(new Date()).map(item => [item.type, item.value]));
      date = `${parts.year}-${parts.month}-${parts.day}`;
    } catch (_) { return { kind: 'error', message: '无法确认天成后台时区，已停止今日金额查询。' }; }
    const url = new URL('/tac/api/relay/get/ods-report-profitloss-summary-get', location.origin);
    url.search = new URLSearchParams({ merchantCode: before.merchant, startDate: date, endDate: date, pid: '31711' }).toString();
    const controller = new AbortController();
    const timeout = window.setTimeout(() => controller.abort(), 20000);
    try {
      const response = await window.fetch(url.href, {
        method: 'GET', credentials: 'include', cache: 'no-store', signal: controller.signal,
        headers: { Accept: 'application/json', Authorization: before.token,
          Merchant: before.merchant, merchantCode: before.merchant,
          platform: before.platform, environment: before.environment, customTimezone: before.timeZone,
          Language: text(read(ls, 'language')) || 'zh_CN' }
      });
      if (stale()) return { kind: 'sessionChanged' };
      if (response.status === 401) return { kind: 'auth', message: '天成数据接口需要登录，请检查当前页面。' };
      if (response.status === 403) return { kind: 'permission', message: '天成拒绝数据查询，请检查平台损益权限或页面验证提示。' };
      if (!response.ok) return { kind: 'error', message: `天成平台损益返回 HTTP ${response.status}。` };
      const payload = await response.json();
      if (stale()) return { kind: 'sessionChanged' };
      if (payload?.success !== true) return { kind: 'error', message: '天成平台损益查询未成功，请检查页面权限或验证提示。' };
      const amount = value => {
        if (typeof value !== 'number' && !(typeof value === 'string' && /^-?\d+(\.\d+)?$/.test(value.trim()))) return null;
        const number = Number(value);
        return Number.isFinite(number) ? number : null;
      };
      const rechargeAmount = amount(payload.value?.deposit), withdrawAmount = amount(payload.value?.withdraw);
      if (rechargeAmount === null || withdrawAmount === null) {
        return { kind: 'error', message: '天成平台损益缺少充值或提现汇总金额，未按零处理。' };
      }
      return { kind: 'ok', dailyFinancial: { countryId, rechargeAmount, withdrawAmount },
        queryContext: { source: 'tiancheng-profitloss', countryId, currency: before.currency,
          timeZone: before.timeZone, date } };
    } catch (error) {
      if (stale()) return { kind: 'sessionChanged' };
      return { kind: 'error', message: error?.name === 'AbortError' ? '天成平台损益查询超过 20 秒。' : '天成平台损益暂时无法读取。' };
    } finally { window.clearTimeout(timeout); }
    """#
}
