import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const read = (file) => fs.readFileSync(new URL('../' + file, import.meta.url), 'utf8');
const script = read('Sources/SMSMonitorApp/AuthenticatedPageSessionScript.swift')
  .match(/static let body = #"""([\s\S]*?)"""#/)[1];

class Storage {
  constructor(entries = []) { this.values = new Map(entries); }
  get length() { return this.values.size; }
  key(index) { return [...this.values.keys()][index]; }
  getItem(key) { return this.values.get(key) ?? null; }
}

const run = (localEntries, sessionEntries = [], expectedUsername = 'blake', memorySignedOut = false) => {
  const window = {
    localStorage: new Storage(localEntries),
    sessionStorage: new Storage(sessionEntries),
    __smsMonitorSignedOut: memorySignedOut,
  };
  const context = vm.createContext({ window, expectedUsername });
  return vm.runInContext(`(() => { ${script} })()`, context);
};

const user = (username, token) => JSON.stringify({ username, token });
assert.equal(run([['lt-user', user('blake', 'current-token')]]).kind, 'authenticated');
assert.equal(run([
  ['lt-user', user('blake', 'revoked-token')],
  ['__smsMonitorSignedOut', '1'],
]).kind, 'signedOut');
assert.equal(run([['lt-user', user('blake', 'current-token')]], [], 'blake', true).kind, 'signedOut');
assert.equal(run([
  ['lt-user', user('blake', 'one')],
  ['prefix-lt-user', user('admin', 'two')],
]).kind, 'accountConflict');
assert.equal(run([['lt-user', user('admin', 'other-token')]]).kind, 'accountMismatch');
assert.equal(run([['lt-user', user('blake', '')]]).kind, 'missingToken');

const controller = read('Sources/SMSMonitorApp/MonitorController.swift');
const recovery = controller.slice(
  controller.indexOf('private func attemptAuthenticatedPageRecovery()'),
  controller.indexOf('private func persistCurrentToken()')
);
assert.match(recovery, /manualAuthenticationRequired[\s\S]*!requiresInteractiveAuthentication/);
assert.match(recovery, /AuthenticatedPageSessionScript\.body/);
assert.match(recovery, /kind == "authenticated"[\s\S]*!token\.isEmpty/);
assert.match(recovery, /manualAuthenticationRequired = false[\s\S]*scheduleNextScan\(after: 0\)/);
assert.match(controller, /guard !manualAuthenticationRequired else \{[\s\S]*attemptAuthenticatedPageRecovery\(\)/);

console.log('PASS: stale native login state recovers only from a matching, non-revoked page session');
