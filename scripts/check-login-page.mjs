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
  constructor() {
    this._value = '';
    this.events = [];
  }

  get value() { return this._value; }
  set value(next) { this._value = String(next); }
  getClientRects() { return [1]; }
  dispatchEvent(event) { this.events.push(event.type); }
}

class FakeButton {
  constructor(text = '') {
    this.textContent = text;
    this.clicked = false;
  }

  getClientRects() { return [1]; }
  click() { this.clicked = true; }
}

class FakeStorage {
  constructor(values) { this.values = values; }
  get length() { return Object.keys(this.values).length; }
  key(index) { return Object.keys(this.values)[index] ?? null; }
  getItem(key) { return this.values[key] ?? null; }
}

const username = new FakeInput();
const password = new FakeInput();
const captcha = new FakeInput();
const totp = new FakeInput();
const loginButton = new FakeButton('Login');
const verifyButton = new FakeButton('Verify');
const location = { pathname: '/dashboard' };

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
      if (selector.includes('#code')) return captcha;
      if (selector.includes('button.login-form-button')) return loginButton;
      return null;
    },
    querySelectorAll(selector) {
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

location.pathname = '/ga-auth';
assert.equal((await context.smsLoginAutomation.snapshot()).kind, 'totp');
const totpResult = await context.smsLoginAutomation.submitTotp({ code: '287082' });
assert.equal(totpResult.submitted, true);
assert.equal(totp.value, '287082');
assert.equal(verifyButton.clicked, true);

console.log('Login-page automation checks passed');
