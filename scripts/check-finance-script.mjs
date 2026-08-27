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
const executeFinance = new AsyncFunction('fallbackToken', 'platformID', 'platformName', match[1]);

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

  setItem(key, value) {
    this.values.set(key, String(value));
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
      origin: 'https://ok01.local.sms-monitor.invalid'
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

globalThis.window = makeWindow(async (url) => {
  if (url.includes('/api/dashboard4bix/realtime')) {
    return {
      ok: true,
      status: 200,
      async json() {
        return {
          status: 0,
          model: {
            chart: [{ rechargeSuccAmount: 706751.7, withdrawSuccAmount: 511000 }],
            today: {
              rechargeSuccAmount: 344524,
              withdrawSuccAmount: 211297
            }
          }
        };
      }
    };
  }
  throw new Error(`unexpected URL ${url}`);
});

const dashboardFinance = await executeFinance('', 'bills', 'BIllS01');
check(dashboardFinance.kind === 'ok', 'accepts dashboard4bix finance response');
check(
  dashboardFinance.dailyFinancial.rechargeAmount === 344524
    && dashboardFinance.dailyFinancial.withdrawAmount === 211297,
  'reads dashboard model.today instead of chart detail amounts'
);

let okbetBody;
let okbetRequestCount = 0;
globalThis.window = makeWindow(async (url, options) => {
  if (url.includes('/api/dashboard4bix/realtime')) {
    throw new Error('OKBET must not request dashboard4bix');
  }
  if (url.includes('/api/realtime_record/with_country')) {
    okbetRequestCount += 1;
    okbetBody = JSON.parse(options.body);
    check(options.headers.SYSTIMEZONE === 'Asia/Manila', 'sends the Philippines system timezone');
    return {
      ok: true,
      status: 200,
      async json() {
        return {
          status: 0,
          list: [
            {
              id: 'PH-hour', countryId: 'PH', type: 'COUNTRY_HOUR', timeType: 'HOUR',
              columns: { rechargeAmount: 2183, withdrawAmount: 2835 }
            },
            {
              id: 'PH-app-day', countryId: 'PH', type: 'COUNTRY_APP_DAY', timeType: 'DAY', appId: 'APP1',
              columns: { rechargeAmount: 12000, withdrawAmount: 8000 }
            },
            {
              id: 'PH-day', countryId: 'PH', type: 'COUNTRY_DAY', timeType: 'DAY',
              columns: { rechargeAmount: 76956, withdrawAmount: 56691 }
            }
          ]
        };
      }
    };
  }
  throw new Error(`unexpected URL ${url}`);
});

const okbetFinance = await executeFinance('', 'custom-a4e42517', 'okbet');
check(okbetFinance.kind === 'ok', 'accepts OKBET with_country finance response');
check(
  okbetRequestCount === 1 && okbetBody.dayOffset === 0 && okbetBody.countryId === 'PH',
  'requests only the OKBET finance endpoint with dayOffset 0 and countryId PH'
);
check(
  okbetFinance.dailyFinancial.rechargeAmount === 76956
    && okbetFinance.dailyFinancial.withdrawAmount === 56691,
  'reads the Philippines COUNTRY_DAY total instead of hourly or app rows'
);

let staleTokenCalls = 0;
globalThis.window = makeWindow(async (url, options) => {
  if (!url.includes('/api/realtime_record/with_country')) {
    throw new Error(`unexpected URL ${url}`);
  }
  staleTokenCalls += 1;
  if (options.headers.Auth === 'test-token') {
    return { ok: true, status: 200, async json() { return { status: 1012, message: 'expired' }; } };
  }
  return {
    ok: true,
    status: 200,
    async json() {
      return {
        status: 0,
        list: [{
          countryId: 'PH', type: 'COUNTRY_DAY', timeType: 'DAY',
          columns: { rechargeAmount: 5000, withdrawAmount: 1200 }
        }]
      };
    }
  };
});
const fallbackFinance = await executeFinance('saved-token', 'custom-a4e42517', 'okbet');
check(
  fallbackFinance.kind === 'auth' && fallbackFinance.manualOnly
    && staleTokenCalls === 1,
  'never retries finance using a different saved account when the page token expires'
);

globalThis.window = makeWindow(async () => {
  throw new Error('fetch should not run without authentication');
}, false);
const unauthenticated = await executeFinance('', 'custom-a4e42517', 'okbet');
check(unauthenticated.kind === 'auth', 'returns auth when no token is present');

console.log('All finance-script checks passed');
