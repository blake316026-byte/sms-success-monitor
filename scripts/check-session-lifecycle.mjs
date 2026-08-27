import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const read = (file) => fs.readFileSync(new URL('../' + file, import.meta.url), 'utf8');
const body = read('Sources/SMSMonitorApp/SessionLifecycleScript.swift').match(/static let body = #"""([\s\S]*?)"""#/)[1];
function context(saved) {
  class Storage {
    values = new Map(saved || []);
    get length() { return this.values.size; }
    key(index) { return [...this.values.keys()][index]; }
    getItem(key) { return this.values.get(key) ?? null; }
    setItem(key, value) { this.values.set(key, String(value)); }
    removeItem(key) { this.values.delete(key); }
    clear() { this.values.clear(); }
  }
  const events = [];
  const window = { localStorage: new Storage(), sessionStorage: new Storage(), webkit: { messageHandlers: { smsSessionLifecycle: { postMessage: e => events.push(e) } } } };
  const sandbox = vm.createContext({ window, Storage });
  vm.runInContext(body, sandbox);
  return { window, events, sandbox };
}
const session = JSON.stringify({ username: 'test', token: 'fake-session-token' });
const eventName = (value) => typeof value === 'string' ? value : value?.event;
for (const mutation of ['clear', 'remove', 'null']) {
  const c = context([['lt-user', session], ['login-data', 'saved-login']]);
  assert.equal(c.events.length, 0, 'startup does not imply logout');
  if (mutation === 'clear') c.window.localStorage.clear();
  if (mutation === 'remove') c.window.localStorage.removeItem('lt-user');
  if (mutation === 'null') c.window.localStorage.setItem('lt-user', 'null');
  assert.equal(eventName(c.events.at(-1)), 'ended');
  assert.equal(c.events.at(-1).username, 'test');
  assert.equal(Object.hasOwn(c.events.at(-1), 'token'), false, 'native notifications contain no token');
  assert.equal(c.window.localStorage.getItem('__smsMonitorSignedOut'), '1');
  c.window.localStorage.setItem('lt-user', session);
  assert.equal(c.window.localStorage.getItem('lt-user'), null, 'late response cannot restore revoked token');
  assert.equal(c.window.__smsMonitorSignedOut, true);
  const refreshed = context([...c.window.localStorage.values]);
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
  c.window.sessionStorage.removeItem('prefix-lt-user');
  assert.equal(eventName(c.events.at(-1)), 'ended', 'prefixed sessionStorage is tracked');
  c.window.localStorage.clear();
  assert.equal(c.window.localStorage.getItem('__smsMonitorSignedOut'), '1', 'clear cannot erase revocation');
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
}
console.log('PASS: logout revokes fallback before fetch, survives reload, and accepts only a new stored session');
