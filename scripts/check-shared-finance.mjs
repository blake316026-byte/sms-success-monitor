import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../clients/shared/finance.js', import.meta.url), 'utf8');
class Storage {
  constructor(values = {}) { this.values = new Map(Object.entries(values)); }
  get length() { return this.values.size; }
  key(index) { return [...this.values.keys()][index] ?? null; }
  getItem(key) { return this.values.get(key) ?? null; }
}
async function execute(fetch, id = 'bills', name = 'BIllS') {
  const context = {
    window: {
      localStorage: new Storage({ 'app-lt-user': JSON.stringify({ token: 'token' }) }),
      sessionStorage: new Storage(),
      location: { origin: 'https://local.invalid', hash: '#CC=eyJDT1VOVFJZIjoiUEgifQ==' },
      atob, setTimeout, clearTimeout, fetch
    },
    URL, URLSearchParams, AbortController, JSON, Number, String, Array, Set, Object, RegExp
  };
  context.globalThis = context;
  vm.runInNewContext(source, context);
  return context.smsMonitorFinance(id, name, '');
}

const dashboard = await execute(async (url) => ({
  ok: true, status: 200,
  async json() {
    if (!url.endsWith('/api/dashboard4bix/realtime')) throw new Error(`unexpected ${url}`);
    return { status: 0, model: { today: { rechargeSuccAmount: 1200, withdrawSuccAmount: 500 } } };
  }
}));
if (dashboard.kind !== 'ok' || dashboard.dailyFinancial.rechargeAmount !== 1200) throw new Error('dashboard finance failed');

const okbet = await execute(async (url, options) => ({
  ok: true, status: 200,
  async json() {
    if (!url.endsWith('/api/realtime_record/with_country')) throw new Error(`unexpected ${url}`);
    const body = JSON.parse(options.body);
    if (body.dayOffset !== 0 || body.countryId !== 'PH') throw new Error('wrong OKBET payload');
    return { status: 0, list: [{ countryId: 'PH', type: 'COUNTRY_DAY', timeType: 'DAY', columns: { rechargeAmount: 900, withdrawAmount: 300 } }] };
  }
}), 'ok01', 'okbet');
if (okbet.kind !== 'ok' || okbet.dailyFinancial.withdrawAmount !== 300) throw new Error('OKBET finance failed');

const forbidden = await execute(async () => ({ ok: false, status: 403, async json() { return {}; } }));
if (forbidden.kind !== 'permission') throw new Error('403 did not become a permission block');
console.log('Shared finance endpoint and permission checks passed');
