import assert from 'node:assert/strict';
import fs from 'node:fs';

const read = (path) => fs.readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const extract = (file) => read(file).match(/static let body = #"""([\s\S]*?)"""#/)[1];
const adapters = [
  ['macOS SMS', new AsyncFunction('sampleLimit', 'fallbackToken', extract('Sources/SMSMonitorApp/ScanScript.swift')), [20, 'old-admin-token']],
  ['macOS finance', new AsyncFunction('fallbackToken', 'platformID', 'platformName', extract('Sources/SMSMonitorApp/FinanceScript.swift')), ['old-admin-token', 'ok01', 'okbet']],
  ['shared SMS', new AsyncFunction('sampleLimit', 'fallbackToken', `${read('clients/shared/scan.js')}\nreturn globalThis.smsMonitorScan(sampleLimit, fallbackToken);`), [20, 'old-admin-token']],
  ['shared finance', new AsyncFunction('platformID', 'platformName', 'fallbackToken', `${read('clients/shared/finance.js')}\nreturn globalThis.smsMonitorFinance(platformID, platformName, fallbackToken);`), ['ok01', 'okbet', 'old-admin-token']],
];

class Storage {
  values = new Map();
  get length() { return this.values.size; }
  key(index) { return [...this.values.keys()][index]; }
  getItem(key) { return this.values.get(key) ?? null; }
  setItem(key, value) { this.values.set(key, value); }
}
const success = {
  status: 0, page: { content: [{ id: 1, status: 'SUCCESS' }], totalElements: 1 },
  model: { today: { rechargeSuccAmount: 100, withdrawSuccAmount: 10 } },
  list: [{ countryId: 'PH', type: 'COUNTRY_DAY', timeType: 'DAY', columns: { rechargeAmount: 100, withdrawAmount: 10 } }],
};
const response = (status, payload = success) => ({ ok: status === 200, status, async json() { return payload; } });
function setup(fetch, user = { username: 'payrobot', token: 'restricted-token' }) {
  globalThis.window = {
    localStorage: new Storage(), sessionStorage: new Storage(),
    location: { origin: 'https://test.invalid', hash: '' },
    atob, setTimeout, clearTimeout, fetch,
  };
  if (user) window.localStorage.setItem('gamebox-admin-lt-user', JSON.stringify(user));
}

for (const [name, run, args] of adapters) {
  for (const [http, payload, expected] of [
    [403, {}, 'permission'], [401, {}, 'auth'],
    [200, { status: 1012, message: 'expired' }, 'auth'],
    [200, { status: 1012, message: 'permission denied' }, 'permission'],
    [200, { status: 403 }, 'permission'],
    [200, { status: 0, message: 'access denied' }, 'permission'],
    [200, success, 'ok'],
  ]) {
    const calls = [];
    setup(async (_url, options) => { calls.push(options.headers.Auth); return response(http, payload); });
    const result = await run(...args);
    assert.equal(result.kind, expected, name);
    assert.deepEqual(calls, ['restricted-token'], `${name}: no old account retry`);
    if (expected === 'auth') {
      assert.equal(result.manualOnly, true, name);
      assert.equal(result.sessionUsername, 'payrobot', `${name}: carries only the current account identity`);
    }
    assert.equal(JSON.parse(window.localStorage.getItem('gamebox-admin-lt-user')).token, 'restricted-token');
  }

  for (const conflict of [false, true]) {
    setup(() => { throw new Error('must not query ambiguous or incomplete sessions'); }, { username: 'payrobot' });
    if (conflict) window.sessionStorage.setItem('gamebox-admin-lt-user', JSON.stringify({ username: 'admin', token: 'other-token' }));
    const result = await run(...args);
    assert.equal(result.kind, 'auth', name);
    assert.equal(result.manualOnly, true, name);
    assert.equal(result.sessionUsername, conflict ? '' : 'payrobot', name);
  }

  for (const stage of ['fetch', 'json']) {
    setup(async () => {
      const switchAccount = () => window.localStorage.setItem('gamebox-admin-lt-user', JSON.stringify({ username: 'new-user', token: 'new-token' }));
      if (stage === 'fetch') switchAccount();
      return { ok: true, status: 200, async json() { switchAccount(); return success; } };
    });
    assert.equal((await run(...args)).kind, 'sessionChanged', `${name}: reject stale ${stage} result`);
  }

  setup(() => { throw new Error('must authenticate before querying'); }, null);
  const missingPageSession = await run(...args);
  assert.equal(missingPageSession.kind, 'auth', `${name}: empty startup session requires login`);
  assert.equal(missingPageSession.manualOnly, false, `${name}: saved profile may auto-login`);
  console.log(`PASS: ${name} account isolation, permission handling and stale-result rejection`);
}

// Permission names and prefix matching are taken from NPG's shipped menu/checkAuth.
for (const [name, run, originalArgs] of adapters) {
  const args = originalArgs.map((arg) => arg === 'ok01' ? 'test' : arg === 'okbet' ? 'test' : arg);
  for (const resources of [[], ['PAY', 'RECHARGE_RECORD_SUMMARY', 'WITHDRAW_RECORD_SUMMARY'], ['_SYSTEM_'], ['SMS_RECORD', 'CK_DASHBOARD_EXTRA'], null]) {
    let calls = 0;
    setup(async () => { calls++; return response(200); }, { username: 'restricted', token: 'current', root: false, resources });
    assert.equal((await run(...args)).kind, 'permission', `${name}: reject missing grants`);
    assert.equal(calls, 0, `${name}: preflight must not send any request`);
  }
  for (const user of [
    { root: true },
    { root: false, resources: ['SMS_RECORD_LIST', 'REPORT', 'CK_DASHBOARD'] },
    { root: false, resources: ['SMS_', 'REPORT', 'CK_'] },
  ]) {
    let calls = 0;
    setup(async () => { calls++; return response(200); }, { username: 'permitted', token: 'current', ...user });
    assert.equal((await run(...args)).kind, 'ok', `${name}: respect explicit grants`);
    assert.equal(calls, 1);
  }
  if (name.includes('finance')) {
    for (const resources of [['REPORT'], ['CK_DASHBOARD']]) {
      setup(() => { throw new Error('partial report permission must not fetch'); }, { username: 'restricted', token: 'current', root: false, resources });
      assert.equal((await run(...args)).kind, 'permission');
    }
  }
  console.log(`PASS: ${name} NPG preflight denies restricted accounts without querying`);
}
