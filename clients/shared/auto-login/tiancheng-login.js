(() => {
  if (globalThis.smsTianchengLogin) return;
  const visible = (el) => Boolean(el && el.getClientRects().length
    && getComputedStyle(el).visibility !== 'hidden');
  const root = () => document.querySelector('.admin-login');
  const field = (id) => root()?.querySelector(`input#${id}`);
  const pauseKey = 'sms-tiancheng-login-paused';
  let manual = false;
  let submitted = '';
  const pause = () => {
    manual = true;
    sessionStorage.setItem(pauseKey, '1');
  };
  for (const type of ['pointerdown', 'keydown', 'paste', 'input']) {
    document.addEventListener(type, (event) => {
      if (event.isTrusted && event.target?.closest('.admin-login input, .admin-login button')) pause();
    }, true);
  }
  const detect = () => Boolean(root()) || [...document.querySelectorAll('script:not([src])')]
    .some((script) => (script.textContent || '').includes('/tac/api/theme_domain/theme'));
  const frame = () => new Promise((resolve) => {
    requestAnimationFrame(resolve);
    setTimeout(resolve, 100);
  });
  const setValue = (el, value) => {
    const before = el.value;
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, value);
    el._valueTracker?.setValue(before);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    el.dispatchEvent(new Event('blur', { bubbles: true }));
  };
  const snapshot = () => {
    if (!detect()) return { kind: 'unknown' };
    if (visible(root())) {
      if (visible(root().querySelector('.login-qrcode')) || visible(field('confirmPassword'))
        || visible(field('newPassword'))) return { kind: 'manual', reason: 'binding-or-password-change' };
      if (manual || sessionStorage.getItem(pauseKey)) return { kind: 'manual', reason: 'manual-or-failed' };
      if (visible(field('operatorName')) && visible(field('password'))) return { kind: 'password' };
      if (visible(field('otp'))) return { kind: 'totp' };
      return { kind: 'waiting' };
    }
    // Do not treat a temporary pre-OTP token or a loading screen as a completed login.
    const loggedIn = ['tabIsLogin', 'isLogin'].some((key) => sessionStorage.getItem(key) === '1')
      && ['TOKEN', 'token'].some((key) => (sessionStorage.getItem(key) || '').length > 12);
    if (loggedIn && location.pathname !== '/') {
      manual = false;
      submitted = '';
      sessionStorage.removeItem(pauseKey);
      return { kind: 'authenticated' };
    }
    return { kind: 'waiting' };
  };
  const submitPassword = async ({ username, password }) => {
    if (snapshot().kind !== 'password' || submitted) return { submitted: false };
    const toggle = root().querySelector('.admin-login-footer button[role="switch"]');
    if (!visible(toggle)) return { submitted: false };
    if (toggle.getAttribute('aria-checked') === 'false') {
      toggle.click();
      await frame();
      await frame();
    }
    if (toggle.getAttribute('aria-checked') !== 'true' || snapshot().kind !== 'password') return { submitted: false };
    const user = field('operatorName');
    const pass = field('password');
    setValue(user, username);
    setValue(pass, password);
    await frame();
    if (snapshot().kind !== 'password' || user.value !== username || pass.value !== password) return { submitted: false };
    const button = user.closest('form')?.querySelector('button[type="submit"]');
    if (!visible(button) || button.disabled) return { submitted: false };
    submitted = 'password';
    button.click();
    return { submitted: true };
  };
  const submitTotp = async ({ code }) => {
    if (snapshot().kind !== 'totp' || submitted === 'totp' || !/^\d{6}$/.test(code)) return { submitted: false };
    const otp = field('otp');
    setValue(otp, code);
    await frame();
    if (snapshot().kind !== 'totp' || otp.value !== code) return { submitted: false };
    const button = otp.closest('form')?.querySelector('button[type="submit"]');
    if (!visible(button) || button.disabled) return { submitted: false };
    submitted = 'totp';
    button.click();
    return { submitted: true };
  };
  const reset = () => {
    manual = false;
    submitted = '';
    sessionStorage.removeItem(pauseKey);
    return true;
  };
  globalThis.smsTianchengLogin = { detect, snapshot, submitPassword, submitTotp, pause, reset };
})();
