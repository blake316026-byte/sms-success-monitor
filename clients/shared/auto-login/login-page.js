(() => {
  if (globalThis.smsLoginAutomation) return;

  const findStoredValue = (suffix) => {
    for (const store of [window.localStorage, window.sessionStorage]) {
      for (let index = 0; index < store.length; index += 1) {
        const key = store.key(index);
        if (!key || (key !== suffix && !key.endsWith(`-${suffix}`))) continue;
        const raw = store.getItem(key);
        if (raw == null) continue;
        try { return JSON.parse(raw); } catch (_) { return raw; }
      }
    }
    return null;
  };

  const visible = (element) => Boolean(
    element
    && element.getClientRects().length
    && getComputedStyle(element).visibility !== 'hidden'
  );

  const setValue = (element, value) => {
    if (!element) return false;
    const prototype = element instanceof HTMLTextAreaElement
      ? HTMLTextAreaElement.prototype
      : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
    if (setter) setter.call(element, String(value || ''));
    else element.value = String(value || '');
    for (const type of ['input', 'change']) {
      element.dispatchEvent(new Event(type, { bubbles: true }));
    }
    return true;
  };

  const captchaImage = () => document.querySelector(
    'img[src*="/api/verify_code/image_code"], img[src*="verify_code"]'
  );

  const waitForImage = async (image, timeout = 12_000) => {
    const startedAt = Date.now();
    while ((!image || !image.complete || image.naturalWidth < 1) && Date.now() - startedAt < timeout) {
      await new Promise((resolve) => setTimeout(resolve, 150));
      image = captchaImage();
    }
    return image;
  };

  const captchaDataUrl = async () => {
    const image = await waitForImage(captchaImage());
    if (!image || !image.naturalWidth || !image.naturalHeight) return '';
    const canvas = document.createElement('canvas');
    canvas.width = image.naturalWidth;
    canvas.height = image.naturalHeight;
    const context = canvas.getContext('2d');
    context.drawImage(image, 0, 0);
    return canvas.toDataURL('image/jpeg', 0.96);
  };

  const extractToken = () => {
    const user = findStoredValue('lt-user');
    return user && typeof user === 'object' ? String(user.token || '') : '';
  };

  const snapshot = async () => {
    const path = window.location.pathname;
    if (path === '/login') {
      return {
        kind: 'login',
        captchaDataUrl: await captchaDataUrl(),
        token: extractToken()
      };
    }
    if (path === '/ga-auth') return { kind: 'totp', token: extractToken() };
    if (path === '/unlock-ip') return { kind: 'unlock-ip', token: extractToken() };
    return { kind: 'authenticated', token: extractToken() };
  };

  const submitLogin = async ({ username, password, captcha }) => {
    const usernameField = document.querySelector('#username, input[name="username"]');
    const passwordField = document.querySelector('#password, input[type="password"]');
    const captchaField = document.querySelector('#code, input[name="code"]');
    if (!visible(usernameField) || !visible(passwordField) || !visible(captchaField)) {
      return { submitted: false, message: '登录输入框尚未加载完成' };
    }
    setValue(usernameField, username);
    setValue(passwordField, password);
    setValue(captchaField, captcha);
    const button = document.querySelector('button.login-form-button, button[type="submit"]');
    if (!visible(button)) return { submitted: false, message: '登录按钮尚未加载完成' };
    button.click();
    return { submitted: true };
  };

  const submitTotp = async ({ code }) => {
    const fields = [...document.querySelectorAll(
      'input.ant-input-lg, input[placeholder*="验证码"], input[placeholder*="verification"]'
    )].filter(visible);
    const field = fields.at(-1);
    if (!field) return { submitted: false, message: 'Google 验证码输入框尚未加载完成' };
    setValue(field, code);
    const buttons = [...document.querySelectorAll('button')].filter(visible);
    const button = buttons.find((candidate) => /verify|验证|確定|提交/i.test(candidate.textContent || ''));
    if (!button) return { submitted: false, message: 'Google 验证提交按钮尚未加载完成' };
    button.click();
    return { submitted: true };
  };

  const refreshCaptcha = () => {
    const image = captchaImage();
    if (!image) return false;
    image.click();
    return true;
  };

  globalThis.smsLoginAutomation = {
    snapshot,
    submitLogin,
    submitTotp,
    extractToken,
    refreshCaptcha
  };
})();
