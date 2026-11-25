enum TianchengMemoryScript {
  // A user-edited page is kept intact until its next navigation. No form or payment replay.
  static let activityObserver = #"""
    (() => {
      if (window.__smsMemoryActivity) return;
      const activity = { touched: false };
      window.__smsMemoryActivity = activity;
      for (const type of ['pointerdown', 'keydown', 'input', 'paste', 'submit'])
        document.addEventListener(type, event => { if (event.isTrusted) activity.touched = true; }, true);
    })();
    """#

  static let context = #"""
    const read = (s,k) => { const v=s.getItem(k); try { return JSON.parse(v); } catch (_) { return v; } };
    const visible = e => Boolean(e && e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden');
    const readOnlyExpiryNotice = e => {
      if (typeof tiancheng === 'undefined' || tiancheng !== false || !e.querySelector) return false;
      const title = e.querySelector('.ant-modal-title')?.textContent?.trim() || '';
      if (!/^域名到期告警(?:\s|[（(]|$)/.test(title)) return false;
      if (e.querySelector('input,textarea,select,form,[contenteditable="true"],[role="switch"],[role="checkbox"]')) return false;
      if (/登录申请|身份验证|验证码|google|authenticator|支付|提现|密码/i.test(e.textContent || '')) return false;
      return [...e.querySelectorAll('button,[role="button"],a')].every(b =>
        b.classList.contains('ant-modal-close') || /^(关闭|知道了|确定)$/.test(b.textContent.trim()));
    };
    const blockReason = () => {
      if (window.__smsChannelsBusy || window.__smsProviderManagementBusy
        || window.__smsPendingOrdersAbort) return 'operation';
      if (['sms-tiancheng-session-attempt-v1','sms-tiancheng-session-manual-v1','sms-tiancheng-login-paused']
        .some(k => sessionStorage.getItem(k))) return 'session';
      if ([...document.querySelectorAll('.ga-verify-modal,.ant-modal-wrap,.ant-drawer,[role="dialog"],.el-dialog__wrapper')]
        .some(e => visible(e) && !readOnlyExpiryNotice(e))) return 'dialog';
      return '';
    };
    const blocked = () => Boolean(blockReason());
    const identity = () => {
      const user=read(sessionStorage,'user')?.operatorName, localUser=read(localStorage,'OPERATOR_NAME');
      const token=read(localStorage,'TOKEN'), pageToken=read(sessionStorage,'token') || read(sessionStorage,'TOKEN');
      if (!expectedUsername || user !== expectedUsername || (localUser && user !== localUser)
        || typeof token !== 'string' || token.length < 13 || token !== pageToken
        || !['isLogin','tabIsLogin'].some(k => sessionStorage.getItem(k) === '1')
        || location.pathname === '/' || visible(document.querySelector('.admin-login'))) return null;
      return JSON.stringify([location.origin,user,token,read(sessionStorage,'platform'),read(sessionStorage,'environment')]);
    };
    const status = async () => {
      if (blocked()) return 'blocked';
      const before=identity();
      if (!before) return 'auth';
      const abort=new AbortController(), timer=setTimeout(() => abort.abort(),7000);
      try {
        const r=await fetch('/tac/api/auth/google/operator-ga-status', {
          method:'GET', credentials:'include', cache:'no-store', redirect:'error', signal:abort.signal,
          headers:{Authorization:read(localStorage,'TOKEN'), platform:read(sessionStorage,'platform') || '',
            environment:read(sessionStorage,'environment') || '', Language:read(localStorage,'language') || 'zh_CN'}
        });
        if (identity() !== before) return 'changed';
        if (blocked()) return 'blocked';
        if (r.status === 401) return 'auth';
        if (!r.ok) return 'unavailable';
        const p=await r.json(), policy=p?.value;
        if (identity() !== before) return 'changed';
        if (blocked()) return 'blocked';
        if (p?.success !== true || typeof policy?.expired !== 'boolean'
          || ![policy.fixedVerifyIntervalMinutes,policy.idleTimeoutMinutes].some(v => Number.isFinite(v) && v>0)
          || !['fixedVerifyIntervalMinutes','idleTimeoutMinutes','fixedVerifyExpireAt','idleExpireAt']
            .every(k => policy[k] === null || (Number.isFinite(policy[k]) && policy[k]>=0))) return 'unavailable';
        return policy.expired ? 'expired' : 'valid';
      } catch (_) { return 'unavailable'; }
      finally { clearTimeout(timer); }
    };
    """#

  static let snapshotGuard = context + #"""
    window.__smsMemorySkipReason = '';
    const reject = reason => { window.__smsMemorySkipReason = reason; return null; };
    if (!window.__smsMemoryActivity) return reject('observer');
    if (window.__smsMemoryActivity.touched) return reject('edited');
    if (blocked()) return reject(blockReason());
    if (tiancheng) {
      // Route-specific merchants must match the fallback used by the lightweight page.
      const route=read(sessionStorage,'merchantPathName')?.[location.pathname.split('/').pop()];
      const merchant=read(sessionStorage,'merchantParam'), merchants=read(sessionStorage,'merchants');
      if (!merchant || (route && route !== merchant) || !Array.isArray(merchants)
        || !merchants.some(m => m.merchantCode === merchant)) return reject('merchant');
      if (await status() !== 'valid' || window.__smsMemoryActivity.touched || blocked()) return reject('verification');
    }
    """#

  static let probe = context + #"""
    if (window.__smsMonitorMemoryCompacted !== true) return 'changed';
    return await status();
    """#
}
