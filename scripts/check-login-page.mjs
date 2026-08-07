import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = fs.readFileSync(
  path.join(root, 'clients/shared/auto-login/login-page.js'),
  'utf8'
);

class FakeInput {
  constructor(attributes = {}, rect = { left: 0, right: 100, top: 0, bottom: 30 }) {
    this._value = '';
    this.events = [];
    this.attributes = attributes;
    this.id = attributes.id ?? '';
    this.rect = rect;
  }

  get value() { return this._value; }
  set value(next) { this._value = String(next); }
  getClientRects() { return [1]; }
  getBoundingClientRect() { return this.rect; }
  getAttribute(name) { return this.attributes[name] ?? null; }
  matches(selector) {
    if (selector.includes('#username') && this.id === 'username') return true;
    if (selector.includes('#password') && this.id === 'password') return true;
    if (selector.includes('#code') && this.id === 'code') return true;
    if (selector.includes('input[name="username"]') && this.attributes.name === 'username') return true;
    if (selector.includes('input[name="code"]') && this.attributes.name === 'code') return true;
    if (selector.includes('input[type="password"]') && this.attributes.type === 'password') return true;
    if (selector === 'input, button') return true;
    return false;
  }
  dispatchEvent(event) { this.events.push(event.type); }
}

class FakeButton {
  constructor(text = '') {
    this.textContent = text;
    this.clicked = false;
  }

  getClientRects() { return [1]; }
  click() { this.clicked = true; }
  matches(selector) { return selector === 'input, button'; }
}

class FakeImage {
  constructor(rect = { left: 220, right: 300, top: 80, bottom: 110 }) {
    this.complete = true;
    this.naturalWidth = 80;
    this.naturalHeight = 30;
    this.rect = rect;
  }
  getClientRects() { return [1]; }
  getBoundingClientRect() { return this.rect; }
}

class FakeStorage {
  constructor(values) { this.values = values; }
  get length() { return Object.keys(this.values).length; }
  key(index) { return Object.keys(this.values)[index] ?? null; }
  getItem(key) { return this.values[key] ?? null; }
}

const username = new FakeInput({ id: 'username', name: 'username' });
const password = new FakeInput({ id: 'password', type: 'password' });
const captcha = new FakeInput({ id: 'code', name: 'code' });
const unnamedCaptcha = new FakeInput({}, { left: 120, right: 218, top: 80, bottom: 110 });
const totp = new FakeInput();
const loginButton = new FakeButton('Login');
const verifyButton = new FakeButton('Verify');
const captchaImage = new FakeImage();
const location = { pathname: '/dashboard' };
let useUnnamedCaptcha = false;

const context = vm.createContext({
  console,
  Event: class Event { constructor(type) { this.type = type; } },
  HTMLInputElement: FakeInput,
  HTMLTextAreaElement: class FakeTextArea extends FakeInput {},
  getComputedStyle: () => ({ visibility: 'visible' }),
  localStorage: new FakeStorage({ 'site-lt-user': JSON.stringify({ token: 'local-token-123' }) }),
  sessionStorage: new FakeStorage({}),
  location,
  setTimeout,
  window: null,
  document: {
    querySelector(selector) {
      if (selector.includes('#username')) return username;
      if (selector.includes('#password')) return password;
      if (selector.includes('#code')) return useUnnamedCaptcha ? null : captcha;
      if (selector.includes('button.login-form-button')) return loginButton;
      if (selector.includes('img[src*="/api/verify_code/image_code"]')) return captchaImage;
      return null;
    },
    querySelectorAll(selector) {
      if (selector === 'input') {
        return useUnnamedCaptcha ? [username, password, unnamedCaptcha] : [username, password, captcha];
      }
      if (selector.includes('input.ant-input-lg')) return [totp];
      if (selector === 'button') return [verifyButton];
      return [];
    }
  }
});
context.window = context;
context.globalThis = context;
vm.runInContext(source, context);

assert.equal(context.smsLoginAutomation.extractToken(), 'local-token-123');
assert.equal((await context.smsLoginAutomation.snapshot()).kind, 'authenticated');

const loginResult = await context.smsLoginAutomation.submitLogin({
  username: 'operator',
  password: 'secret',
  captcha: 'nRVr'
});
assert.equal(loginResult.submitted, true);
assert.equal(username.value, 'operator');
assert.equal(password.value, 'secret');
assert.equal(captcha.value, 'nRVr');
assert.equal(loginButton.clicked, true);

useUnnamedCaptcha = true;
loginButton.clicked = false;
const fallbackLoginResult = await context.smsLoginAutomation.submitLogin({
  username: 'operator2',
  password: 'secret2',
  captcha: 'a9Zx'
});
assert.equal(fallbackLoginResult.submitted, true);
assert.equal(unnamedCaptcha.value, 'a9Zx');
assert.equal(loginButton.clicked, true);

location.pathname = '/ga-auth';
assert.equal((await context.smsLoginAutomation.snapshot()).kind, 'totp');
const totpResult = await context.smsLoginAutomation.submitTotp({ code: '287082' });
assert.equal(totpResult.submitted, true);
assert.equal(totp.value, '287082');
assert.equal(verifyButton.clicked, true);

console.log('Login-page automation checks passed');
