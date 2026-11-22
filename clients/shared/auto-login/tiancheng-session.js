(() => {
  if (globalThis.smsTianchengSession) return;
  const visible = el => Boolean(el && el.getClientRects().length && getComputedStyle(el).visibility !== 'hidden');
  const read = (storage, key) => { const value = storage.getItem(key); try { return JSON.parse(value); } catch { return value; } };
  const attemptKey = 'sms-tiancheng-session-attempt-v1';
  const manualKey = 'sms-tiancheng-session-manual-v1';
  let challenge = null, sequence = 0, busy = false;
  const modals = () => [...document.querySelectorAll('.ga-verify-modal')].filter(visible);
  const identity = username => {
    const token = read(localStorage, 'TOKEN');
    const sessionToken = read(sessionStorage, 'token') || read(sessionStorage, 'TOKEN');
    const user = read(sessionStorage, 'user')?.operatorName;
    const operator = read(localStorage, 'OPERATOR_NAME');
    if (!globalThis.smsTianchengLogin?.detect() || visible(document.querySelector('.admin-login'))
      || location.pathname === '/' || !username || user !== username || (operator && operator !== username)
      || !['tabIsLogin', 'isLogin'].some(key => sessionStorage.getItem(key) === '1')
      || typeof token !== 'string' || token.length < 13 || token !== sessionToken) throw Error('identity');
    return JSON.stringify([location.origin, user, token]);
  };
  const status = async (username, context) => {
    if (identity(username) !== context) throw Error('identity');
    const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 7000);
    try {
      const response = await fetch('/tac/api/auth/google/operator-ga-status', {
        method: 'GET', credentials: 'include', cache: 'no-store', redirect: 'error', signal: controller.signal,
        headers: { Authorization: read(localStorage, 'TOKEN'), platform: read(sessionStorage, 'platform') || '',
          environment: read(sessionStorage, 'environment') || '', Language: read(localStorage, 'language') || 'zh_CN' }
      });
      if (identity(username) !== context || !response.ok) throw Error('status');
      const payload = await response.json();
      if (identity(username) !== context || payload?.success !== true) throw Error('status');
      const policy = payload.value;
      if (!policy || typeof policy.expired !== 'boolean'
        || ![policy.fixedVerifyIntervalMinutes, policy.idleTimeoutMinutes].some(v => Number.isFinite(v) && v > 0)
        || !['fixedVerifyIntervalMinutes', 'idleTimeoutMinutes', 'fixedVerifyExpireAt', 'idleExpireAt']
          .every(key => policy[key] === null || (Number.isFinite(policy[key]) && policy[key] >= 0))) throw Error('policy');
      return policy;
    } finally { clearTimeout(timer); }
  };
  const signature = policy => JSON.stringify([policy.fixedVerifyExpireAt, policy.idleExpireAt]);
  const sessionModal = () => {
    const all = modals();
    if (all.length !== 1) return null;
    const modal = all[0], wrap = modal.closest('.ant-modal-wrap');
    // The operation gate uses the same six inputs, but z-index 2001 and a five-minute hint.
    const hint = [...modal.querySelectorAll('.ga-verify-hint')].filter(visible).at(-1)?.textContent || '';
    if (!wrap || getComputedStyle(wrap).zIndex !== '2002') return null;
    const inputs = [...modal.querySelectorAll('input')].filter(visible);
    const buttons = [...modal.querySelectorAll('.ant-modal-footer button.ant-btn-primary')].filter(visible);
    return inputs.length === 6 && buttons.length === 1 ? { modal, inputs, button: buttons[0], hint } : null;
  };
  const shapeSummary = () => modals().slice(0, 3).map(modal => {
    const wrap = modal.closest('.ant-modal-wrap');
    const z = wrap ? Number(getComputedStyle(wrap).zIndex) : NaN;
    const hint = [...modal.querySelectorAll('.ga-verify-hint')].filter(visible).at(-1)?.textContent || '';
    return { z: Number.isFinite(z) ? z : -1,
      inputs: Math.min(99, [...modal.querySelectorAll('input')].filter(visible).length),
      buttons: Math.min(99, [...modal.querySelectorAll('.ant-modal-footer button.ant-btn-primary')].filter(visible).length),
      gaHint: /(GA|Google|谷歌)/i.test(hint), minuteHint: /(分钟|分鐘|minutes?|mins?)/i.test(hint) };
  });
  const matchesPolicy = (shape, policy) => {
    // TAC omits the combined notice when either policy is null. Server status remains authoritative.
    if (!/(GA|Google|谷歌)/i.test(shape.hint) || !/(分钟|分鐘|minutes?|mins?)/i.test(shape.hint)) return true;
    return [policy.fixedVerifyIntervalMinutes, policy.idleTimeoutMinutes]
      .filter(value => Number.isFinite(value) && value > 0)
      .every(value => new RegExp('(^|[^0-9])' + value + '([^0-9]|$)').test(shape.hint));
  };
  const errorVisible = shape => [...shape.modal.querySelectorAll('.ga-verify-error')].some(el => visible(el) && el.textContent.trim());
  const manual = reason => { sessionStorage.setItem(manualKey, '1'); return { kind: 'manual', reason }; };
  for (const type of ['pointerdown', 'keydown', 'paste', 'input']) document.addEventListener(type, event => {
    if (event.isTrusted && event.target?.closest('.ga-verify-modal')) sessionStorage.setItem(manualKey, '1');
  }, true);
  const snapshot = async ({ username }) => {
    if (busy) return { kind: 'waiting' };
    busy = true;
    try {
      const attempt = read(sessionStorage, attemptKey);
      if (!modals().length && !attempt) { challenge = null; return { kind: 'none' }; }
      if (modals().length && sessionStorage.getItem(manualKey)) return { kind: 'manual', reason: 'manual-takeover' };
      const shape = sessionModal();
      if (modals().length && !shape) return { kind: 'operation', reason: 'not-session-verification', shapes: shapeSummary() };
      const context = identity(username), policy = await status(username, context);
      if (policy.expired === false) {
        if (modals().length) return attempt && Date.now() - attempt.at >= 20000 ? manual('modal-not-closed') : { kind: 'waiting' };
        sessionStorage.removeItem(attemptKey); sessionStorage.removeItem(manualKey); challenge = null;
        return { kind: attempt ? 'verified' : 'none' };
      }
      if (!shape || sessionModal()?.modal !== shape.modal || !matchesPolicy(shape, policy)) return { kind: 'waiting' };
      if (errorVisible(shape)) return manual('verification-error');
      const sig = signature(policy);
      if (attempt) return Date.now() - attempt.at < 20000 ? { kind: 'waiting' } : manual('unconfirmed');
      if (shape.inputs.some(input => input.value)) return manual('existing-input');
      if (!challenge || challenge.context !== context || challenge.signature !== sig || challenge.modal !== shape.modal)
        challenge = { id: String(++sequence) + ':' + Date.now(), context, signature: sig, modal: shape.modal };
      return { kind: 'required', challenge: challenge.id, fixedMinutes: policy.fixedVerifyIntervalMinutes, idleMinutes: policy.idleTimeoutMinutes };
    } catch (error) {
      return { kind: 'unavailable', reason: ['identity', 'status', 'policy'].includes(error.message) ? error.message : 'read-error' };
    }
    finally { busy = false; }
  };
  const frame = () => new Promise(resolve => { requestAnimationFrame(resolve); setTimeout(resolve, 100); });
  const submit = async ({ username, code, challengeID }) => {
    if (busy || !/^\d{6}$/.test(code) || !challenge || challenge.id !== challengeID
      || sessionStorage.getItem(manualKey) || sessionStorage.getItem(attemptKey)) return { submitted: false };
    busy = true;
    try {
      const original = challenge, context = identity(username), policy = await status(username, context);
      const shape = sessionModal();
      const valid = () => identity(username) === original.context && context === original.context
        && challenge === original && sessionModal()?.modal === shape?.modal && shape?.modal === original.modal
        && !sessionStorage.getItem(manualKey) && !sessionStorage.getItem(attemptKey);
      if (!valid() || !policy.expired || signature(policy) !== original.signature || !matchesPolicy(shape, policy)
        || errorVisible(shape)) return { submitted: false };
      if (shape.button.disabled || shape.inputs.some(el => el.disabled || el.readOnly)) return { submitted: false, retryable: true };
      for (let index = 0; index < 6; index++) {
        if (!valid()) return { submitted: false };
        const input = sessionModal().inputs[index], before = input.value;
        Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(input, code[index]);
        input._valueTracker?.setValue(before);
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
        await frame();
      }
      const final = sessionModal();
      if (!valid() || final.inputs.map(input => input.value).join('') !== code || final.button.disabled) return { submitted: false };
      // Persist before clicking. A lost callback or reload never replays the challenge.
      sessionStorage.setItem(attemptKey, JSON.stringify({ at: Date.now(), signature: original.signature }));
      final.button.click();
      return { submitted: true };
    } catch { return { submitted: false }; }
    finally { busy = false; }
  };
  const reset = () => { challenge = null; sessionStorage.removeItem(manualKey); sessionStorage.removeItem(attemptKey); };
  globalThis.smsTianchengSession = { snapshot, submit, reset };
})();
