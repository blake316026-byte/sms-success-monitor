import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const sourcePath = path.join(scriptDirectory, '..', 'Sources', 'SMSMonitorApp', 'FinanceScript.swift');
const source = fs.readFileSync(sourcePath, 'utf8');
const match = source.match(/static let body = #"""([\s\S]*?)"""#/);

if (!match) {
  throw new Error('Unable to extract FinanceScript.body');
}

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const executeFinance = new AsyncFunction('fallbackToken', match[1]);

class MemoryStorage {
  constructor(values = {}) {
    this.values = new Map(Object.entries(values));
  }

  get length() {
    return this.values.size;
  }

  key(index) {
    return Array.from(this.values.keys())[index] ?? null;
  }

  getItem(key) {
    return this.values.get(key) ?? null;
  }
}

function makeWindow(fetchImplementation, authenticated = true) {
  const localValues = authenticated
    ? {
        'gamebox-admin-lt-user': JSON.stringify({ token: 'test-token' }),
        'gamebox-admin-locale': JSON.stringify('zh-cn')
      }
    : {};

  return {
    localStorage: new MemoryStorage(localValues),
    sessionStorage: new MemoryStorage(),
    location: {
      hash: '#CC=eyJDT1VOVFJZIjoiUEgifQ==',
      origin: 'https://zwpeq3.sixsass.com'
    },
    atob,
    setTimeout,
    clearTimeout,
    fetch: fetchImplementation
  };
}

function check(condition, message) {
  if (!condition) {
    throw new Error(`FAIL: ${message}`);
  }
  console.log(`PASS: ${message}`);
}

let okbetBody;
globalThis.window = makeWindow(async (url, options) => {
  if (url.includes('/api/dashboard4bix/realtime')) {
    return { ok: true, status: 200, async json() { return { status: 1012 }; } };
  }
  if (url.includes('/api/realtime_record/with_country')) {
    okbetBody = JSON.parse(options.body);
    return {
      ok: true,
      status: 200,
      async json() {
        return {
          code: 0,
          data: {
            chart: [
              {
                rechargeAmount: 1810,
                withdrawAmount: 1000
              }
            ],
            record: {
              rechargeAmount: '26129',
              withdrawAmount: 20329
            }
          }
        };
      }
    };
  }
  throw new Error(`unexpected URL ${url}`);
});

const okbetFinance = await executeFinance('');
check(okbetFinance.kind === 'ok', 'accepts OKBET with_country finance response');
check(
  okbetBody.dayOffset === 0 && okbetBody.countryId === 'PH',
  'requests OKBET finance with dayOffset 0 and countryId PH'
);
check(
  okbetFinance.dailyFinancial.rechargeAmount === 26129
    && okbetFinance.dailyFinancial.withdrawAmount === 20329,
  'prefers OKBET daily totals over chart detail amounts'
);

globalThis.window = makeWindow(async () => {
  throw new Error('fetch should not run without authentication');
}, false);
const unauthenticated = await executeFinance('');
check(unauthenticated.kind === 'auth', 'returns auth when no token is present');

console.log('All finance-script checks passed');
