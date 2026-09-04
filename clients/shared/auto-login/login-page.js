(() => {
  if (globalThis.smsLoginAutomation) return;

  const findStoredValue = (suffix) => {
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

  const visible = (element) => Boolean(
    element
    && element.getClientRects().length
    && getComputedStyle(element).visibility !== 'hidden'
  );

  const loginControlSelector = [
    '#username',
    'input[name="username"]',
    '#password',
    'input[type="password"]',
    '#code',
    'input[name="code"]',
    'input[placeholder*="验证码"]',
    'input[placeholder*="code" i]',
    'input[placeholder*="captcha" i]'
  ].join(', ');
  let manualLoginActive = false;
  let clockSample = null;

  const isLoginControl = (element) => Boolean(
    element
    && typeof element.matches === 'function'
    && (
      element.matches(loginControlSelector)
      || (window.location.pathname === '/login' && element.matches('input, button'))
    )
  );

  const markManualLogin = (event) => {
    if (!event.isTrusted) return;
    if (isLoginControl(event.target)
      || (event.type === 'pointerdown' && event.target === captchaImage())) {
      manualLoginActive = true;
    }
  };

  if (typeof document.addEventListener === 'function') {
    for (const type of ['pointerdown', 'keydown', 'paste', 'input']) {
      document.addEventListener(type, markManualLogin, true);
    }
  }

  const setValue = (element, value) => {
    if (!element) return false;
    const prototype = element instanceof HTMLTextAreaElement
      ? HTMLTextAreaElement.prototype
      : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
    const nextValue = String(value ?? '');
    const previousValue = element.value;
    if (setter) setter.call(element, nextValue);
    else element.value = nextValue;
    // React tracks the last value assigned through its own setter. Reset its
    // tracker so the synthetic input is treated as a real user edit.
    try {
      const tracker = element._valueTracker;
      if (tracker && typeof tracker.setValue === 'function') tracker.setValue(previousValue);
    } catch (_) {}
    const inputEvent = typeof InputEvent === 'function'
      ? new InputEvent('input', { bubbles: true, inputType: 'insertText', data: nextValue })
      : new Event('input', { bubbles: true });
    element.dispatchEvent(inputEvent);
    element.dispatchEvent(new Event('change', { bubbles: true }));
    element.dispatchEvent(new Event('blur', { bubbles: true }));
    return true;
  };

  const captchaImage = () => document.querySelector(
    'img[src*="/api/verify_code/image_code"], img[src*="verify_code"]'
  );

  const visibleInputs = () => [...document.querySelectorAll('input')]
    .filter((element) => {
      if (!visible(element)) return false;
      const type = String(element.getAttribute('type') || 'text').toLowerCase();
      return !['hidden', 'password', 'checkbox', 'radio', 'submit', 'button'].includes(type);
    });

  const captchaField = () => {
    const preferred = visibleInputs().find((element) => {
      const id = String(element.id || '').toLowerCase();
      const name = String(element.getAttribute('name') || '').toLowerCase();
      const placeholder = String(element.getAttribute('placeholder') || '').toLowerCase();
      return id === 'code'
        || name === 'code'
        || id.includes('captcha')
        || name.includes('captcha')
        || placeholder.includes('验证码')
        || placeholder.includes('code')
        || placeholder.includes('captcha');
    });
    if (preferred) return preferred;

    const image = captchaImage();
    if (!image || typeof image.getBoundingClientRect !== 'function') return null;
    const imageRect = image.getBoundingClientRect();
    let best = null;
    let bestDistance = Number.POSITIVE_INFINITY;
    for (const input of visibleInputs()) {
      if (input.matches('#username, input[name="username"]')) continue;
      if (typeof input.getBoundingClientRect !== 'function') continue;
      const rect = input.getBoundingClientRect();
      const horizontalGap = Math.max(0, imageRect.left - rect.right, rect.left - imageRect.right);
      const verticalGap = Math.max(0, imageRect.top - rect.bottom, rect.top - imageRect.bottom);
      const distance = horizontalGap + verticalGap;
      if (distance < bestDistance) {
        best = input;
        bestDistance = distance;
      }
    }
    return best;
  };

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

  const readClockOffsetMs = async () => {
    const now = Date.now();
    const maxAge = clockSample?.calibrated ? 300_000 : 30_000;
    if (clockSample && now - clockSample.sampledAt < maxAge) return clockSample.offsetMs;

    const controller = typeof AbortController === 'function' ? new AbortController() : null;
    const timeout = controller ? setTimeout(() => controller.abort(), 3_000) : null;
    try {
      const probe = new URL(window.location.href);
      probe.hash = '';
      probe.searchParams.set('__sms_clock_probe', String(now));
      const response = await fetch(probe.toString(), {
        method: 'HEAD',
        cache: 'no-store',
        credentials: 'same-origin',
        signal: controller?.signal
      });
      const serverTime = Date.parse(response.headers.get('date') || '');
      if (!Number.isFinite(serverTime)) throw new Error('missing server date');
      const offsetMs = serverTime + 500 - Date.now();
      clockSample = { calibrated: true, offsetMs, sampledAt: Date.now() };
      return offsetMs;
    } catch (_) {
      clockSample = { calibrated: false, offsetMs: 0, sampledAt: Date.now() };
      return 0;
    } finally {
      if (timeout) clearTimeout(timeout);
    }
  };

  const extractToken = (expectedUsername = '') => {
    const user = findStoredValue('lt-user');
    if (expectedUsername && String(user?.username || user?.account || user?.loginName || '').trim() !== expectedUsername) return '';
    return user && typeof user === 'object' ? String(user.token || '') : '';
  };

  const loginIdentity = () => {
    const usernameField = document.querySelector('#username, input[name="username"]');
    return {
      username: visible(usernameField) ? String(usernameField.value || '').trim() : '',
      manual: manualLoginActive
    };
  };

  const snapshot = async () => {
    const path = window.location.pathname;
    if (path === '/login') {
      if (manualLoginActive) {
        return { kind: 'manual', token: extractToken(), clockOffsetMs: await readClockOffsetMs() };
      }
      const [captcha, clockOffsetMs] = await Promise.all([
        captchaDataUrl(),
        readClockOffsetMs()
      ]);
      return {
        kind: 'login',
        captchaDataUrl: captcha,
        token: extractToken(),
        clockOffsetMs
      };
    }
    manualLoginActive = false;
    const clockOffsetMs = await readClockOffsetMs();
    if (path === '/ga-auth') return { kind: 'totp', token: extractToken(), clockOffsetMs };
    if (path === '/unlock-ip') return { kind: 'unlock-ip', token: extractToken(), clockOffsetMs };
    return { kind: 'authenticated', token: extractToken(), clockOffsetMs };
  };

  const submitLogin = async ({ username, password, captcha }) => {
    if (manualLoginActive) {
      return { submitted: false, manual: true, message: '检测到人工输入，自动登录已暂停' };
    }
    const usernameField = document.querySelector('#username, input[name="username"]');
    const passwordField = document.querySelector('#password, input[type="password"]');
    const codeField = captchaField();
    if (!visible(usernameField) || !visible(passwordField) || !visible(codeField)) {
      return { submitted: false, message: '登录输入框尚未加载完成' };
    }
    setValue(usernameField, username);
    setValue(passwordField, password);
    setValue(codeField, captcha);
    await new Promise((resolve) => {
      // Background WebViews can suspend animation frames indefinitely.
      const timeout = setTimeout(resolve, 50);
      if (typeof requestAnimationFrame === 'function') requestAnimationFrame(() => {
        clearTimeout(timeout);
        resolve();
      });
    });
    if (manualLoginActive) {
      return { submitted: false, manual: true, message: '检测到人工输入，自动登录已暂停' };
    }
    if (usernameField.value !== String(username ?? '')
      || passwordField.value !== String(password ?? '')
      || codeField.value !== String(captcha ?? '')) {
      return { submitted: false, message: '登录输入框未正确接收内容' };
    }
    const button = document.querySelector('button.login-form-button, button[type="submit"]');
    if (!visible(button)) return { submitted: false, message: '登录按钮尚未加载完成' };
    // The platform binds its login handler to the button click. Calling only
    // requestSubmit can run native validation while skipping that handler.
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
    if (manualLoginActive) return false;
    const image = captchaImage();
    if (!image) return false;
    image.click();
    return true;
  };

  globalThis.smsLoginAutomation = {
    loginIdentity,
    snapshot,
    submitLogin,
    submitTotp,
    extractToken,
    refreshCaptcha
  };
})();
