import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const read = (file) => fs.readFileSync(new URL('../' + file, import.meta.url), 'utf8');
const body = read('Sources/SMSMonitorApp/SessionLifecycleScript.swift').match(/static let body = #"""([\s\S]*?)"""#/)[1];
function context(saved, pathname = '/dashboard') {
  class Storage {
    constructor(values = []) { this.values = new Map(values); }
    get length() { return this.values.size; }
    key(index) { return [...this.values.keys()][index]; }
    getItem(key) { return this.values.get(key) ?? null; }
    setItem(key, value) { this.values.set(key, String(value)); }
    removeItem(key) { this.values.delete(key); }
    clear() { this.values.clear(); }
  }
  const events = [];
  const window = {
    localStorage: new Storage(saved || []), sessionStorage: new Storage(),
    location: { pathname }, setTimeout, __smsMonitorSessionEndDelay: 10,
    webkit: { messageHandlers: { smsSessionLifecycle: { postMessage: e => events.push(e) } } }
  };
  const sandbox = vm.createContext({ window, Storage });
  vm.runInContext(body, sandbox);
  return { window, events, sandbox };
}
const session = JSON.stringify({ username: 'test', token: 'fake-session-token' });
const eventName = (value) => typeof value === 'string' ? value : value?.event;
for (const mutation of ['clear', 'remove', 'null']) {
  const c = context([['lt-user', session], ['login-data', 'saved-login']], '/dashboard');
  assert.equal(c.events.length, 0, 'startup does not imply logout');
  if (mutation === 'clear') c.window.localStorage.clear();
  if (mutation === 'remove') c.window.localStorage.removeItem('lt-user');
  if (mutation === 'null') c.window.localStorage.setItem('lt-user', 'null');
  c.window.localStorage.setItem('lt-user', session);
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(c.events.some((event) => eventName(event) === 'ended'), false, 'temporary token rotation does not imply logout');
  assert.equal(c.window.localStorage.getItem('__smsMonitorSignedOut'), null);

  c.window.location.pathname = '/login';
  c.window.localStorage.removeItem('lt-user');
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(eventName(c.events.at(-1)), 'ended', `${mutation} on /login confirms logout`);
  assert.equal(c.events.at(-1).username, 'test');
  assert.equal(Object.hasOwn(c.events.at(-1), 'token'), false, 'native notifications contain no token');
  assert.equal(c.window.localStorage.getItem('__smsMonitorSignedOut'), '1');
  c.window.localStorage.setItem('lt-user', session);
  assert.equal(c.window.localStorage.getItem('lt-user'), null, 'confirmed logout blocks a late revoked token');
  assert.equal(c.window.__smsMonitorSignedOut, true);
  const refreshed = context([...c.window.localStorage.values], '/login');
  assert.equal(refreshed.window.__smsMonitorSignedOut, true, 'refresh retains revocation');
  assert.equal(eventName(refreshed.events[0]), 'ended');
  assert.equal(refreshed.events[0].username, 'test', 'refresh retains the signed-out account identity');
  refreshed.window.localStorage.setItem('lt-user', JSON.stringify({ username: 'test', token: 'fresh-token' }));
  assert.equal(refreshed.events.at(-1), 'authenticated');
  assert.equal(refreshed.window.__smsMonitorSignedOut, false);
  assert.equal(refreshed.window.localStorage.getItem('__smsMonitorSignedOut'), null);
}
const c = context();
{
  c.window.sessionStorage.setItem('prefix-lt-user', session);
  c.window.location.pathname = '/login';
  c.window.sessionStorage.removeItem('prefix-lt-user');
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(eventName(c.events.at(-1)), 'ended', 'prefixed sessionStorage is tracked');
  c.window.localStorage.clear();
  assert.equal(c.window.localStorage.getItem('__smsMonitorSignedOut'), '1', 'clear cannot erase revocation');
}
for (const pathname of ['/ga-auth', '/unlock-ip']) {
  const intermediate = context([['lt-user', session]], pathname);
  intermediate.window.localStorage.removeItem('lt-user');
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(
    intermediate.events.some((event) => eventName(event) === 'ended'),
    false,
    `${pathname} is an intermediate authentication route, not an explicit logout`
  );
  assert.equal(intermediate.window.localStorage.getItem('__smsMonitorSignedOut'), null);
}
const AsyncFunction = Object.getPrototypeOf(async function() {}).constructor;
for (const [file, args, values] of [
  ['Sources/SMSMonitorApp/ScanScript.swift', ['sampleLimit', 'fallbackToken'], [20, 'old-token']],
  ['Sources/SMSMonitorApp/FinanceScript.swift', ['fallbackToken', 'platformID', 'platformName'], ['old-token', 'test', 'test']],
]) {
  const code = read(file).match(/static let body = #"""([\s\S]*?)"""#/)[1];
  globalThis.window = { ...c.window, location: { hash: '', origin: 'https.invalid' }, fetch() { throw Error('must not query after logout'); } };
  const result = await new AsyncFunction(...args, code)(...values);
  assert.equal(result.kind, 'auth');
  assert.equal(result.manualOnly, true);
  assert.equal(result.sessionUsername, 'test');
}
console.log('PASS: token rotation is tolerated while confirmed logout revokes fallback and survives reload');
