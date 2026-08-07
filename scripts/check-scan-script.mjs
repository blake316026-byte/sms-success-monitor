import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const sourcePath = path.join(scriptDirectory, '..', 'Sources', 'SMSMonitorApp', 'ScanScript.swift');
const source = fs.readFileSync(sourcePath, 'utf8');
const match = source.match(/static let body = #"""([\s\S]*?)"""#/);

if (!match) {
  throw new Error('Unable to extract ScanScript.body');
}

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const executeScan = new AsyncFunction('sampleLimit', 'fallbackToken', match[1]);

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
      origin: 'https://qgxucm.npgaaa.com'
    },
    atob,
    setTimeout,
    clearTimeout,
    fetch: fetchImplementation
  };
}

function responseFor(rows, totalElements = rows.length) {
  return {
    ok: true,
    status: 200,
    async json() {
      return {
        status: 0,
        page: { content: rows, totalElements }
      };
    }
  };
}

function dashboardResponse(rechargeAmount = 712323.4, withdrawAmount = 409663.9) {
  return {
    ok: true,
    status: 200,
    async json() {
      return {
        status: 0,
        model: { today: { rechargeSuccAmount: rechargeAmount, withdrawSuccAmount: withdrawAmount } }
      };
    }
  };
}

function check(condition, message) {
  if (!condition) {
    throw new Error(`FAIL: ${message}`);
  }
  console.log(`PASS: ${message}`);
}

globalThis.window = makeWindow(async () => {
  throw new Error('fetch should not run without authentication');
}, false);
const unauthenticated = await executeScan(200, '');
check(unauthenticated.kind === 'auth', 'returns an authentication state when no token is present');

let singlePageCalls = 0;
let singlePageQuery;
globalThis.window = makeWindow(async (url, options) => {
  if (url.includes('/api/dashboard4bix/realtime')) return dashboardResponse();
  singlePageCalls += 1;
  singlePageQuery = JSON.parse(options.body).query;
  const rows = Array.from({ length: 200 }, (_, index) => ({
    id: `single-${index}`,
    status: index < 120 ? 'SUCCESS' : 'SENT'
  }));
  return responseFor(rows, 5000);
});
const singlePage = await executeScan(200, '');
check(singlePage.kind === 'ok', 'accepts a successful API response');
check(singlePage.statuses.length === 200, 'returns exactly 200 statuses from a full page');
check(singlePage.statuses.filter((status) => status === 'SUCCESS').length === 120, 'preserves raw SUCCESS statuses');
check(singlePageQuery.pageSize === 20, 'requests the SMS record API with pageSize 20');
check(
  singlePage.dailyFinancial.rechargeAmount === 712323.4
    && singlePage.dailyFinancial.withdrawAmount === 409663.9,
  'reads today recharge and withdrawal amounts in the same scan'
);
check(
  Number.isFinite(singlePageQuery.ddCreated.start)
    && Number.isFinite(singlePageQuery.ddCreated.finish)
    && singlePageQuery.ddCreated.finish > singlePageQuery.ddCreated.start,
  'queries the same recent creation-date window used by the SMS record page'
);

globalThis.window = makeWindow(async (url) => {
  if (url.includes('/api/dashboard4bix/realtime')) throw new Error('finance unavailable');
  return responseFor([{ id: 'finance-independent', status: 'SUCCESS' }], 1);
});
const financeUnavailable = await executeScan(200, '');
check(
  financeUnavailable.kind === 'ok'
    && financeUnavailable.statuses.length === 1
    && financeUnavailable.dailyFinancial === null,
  'keeps SMS monitoring healthy when the finance dashboard is unavailable'
);

let sassDashboardBody;
globalThis.window = makeWindow(async (url, options) => {
  if (url.includes('/api/dashboard4bix/realtime')) {
    return { ok: true, status: 200, async json() { return { status: 1012 }; } };
  }
  if (url.includes('/api/realtime_record/with_country')) {
    sassDashboardBody = JSON.parse(options.body);
    return {
      ok: true,
      status: 200,
      async json() {
        return {
          code: 0,
          data: {
            record: {
              rechargeAmount: 120196,
              withdrawAmount: 85521
            }
          }
        };
      }
    };
  }
  return responseFor([{ id: 'sass-finance', status: 'SUCCESS' }], 1);
});
const sassFinance = await executeScan(200, '');
check(
  sassFinance.dailyFinancial.rechargeAmount === 120196
    && sassFinance.dailyFinancial.withdrawAmount === 85521
    && sassDashboardBody.dayOffset === 0
    && sassDashboardBody.countryId === 'PH',
  'reads sixsass with_country recharge and withdrawal amounts'
);

let cappedPageCalls = 0;
globalThis.window = makeWindow(async (url, options) => {
  if (url.includes('/api/dashboard4bix/realtime')) return dashboardResponse();
  cappedPageCalls += 1;
  const pageNo = JSON.parse(options.body).query.pageNo;
  const rows = Array.from({ length: 20 }, (_, index) => ({
    id: `capped-${pageNo}-${index}`,
    status: index % 2 === 0 ? 'SUCCESS' : 'FAILED'
  }));
  return responseFor(rows, 1000);
});
const cappedPages = await executeScan(200);
check(cappedPages.statuses.length === 200, 'continues paging when the server caps each page at 20 rows');
check(cappedPageCalls === 10, 'stops after collecting 200 rows across ten capped pages');

let configuredPageCalls = 0;
globalThis.window = makeWindow(async (url, options) => {
  if (url.includes('/api/dashboard4bix/realtime')) return dashboardResponse();
  configuredPageCalls += 1;
  const pageNo = JSON.parse(options.body).query.pageNo;
  const rows = Array.from({ length: 20 }, (_, index) => ({
    id: `configured-${pageNo}-${index}`,
    status: 'SUCCESS'
  }));
  return responseFor(rows, 1000);
});
const configuredPages = await executeScan(350);
check(configuredPages.statuses.length === 350, 'returns the manually configured sample count');
check(configuredPageCalls === 18, 'fetches enough capped pages for a configured sample count');

let fallbackTokenSeen = false;
globalThis.window = makeWindow(async (url, options) => {
  if (url.includes('/api/dashboard4bix/realtime')) return dashboardResponse();
  fallbackTokenSeen = options.headers.Auth === 'saved-token';
  return responseFor([{ id: 'fallback-1', status: 'SUCCESS' }], 1);
}, false);
const fallbackTokenResult = await executeScan(200, 'saved-token');
check(
  fallbackTokenResult.kind === 'ok' && fallbackTokenSeen,
  'uses the encrypted saved token before starting automatic login'
);
check(
  fallbackTokenResult.tokenSource === 'fallback' && fallbackTokenResult.restoredPageSession === false,
  'reports when the saved token worked but no page session existed to restore'
);

let staleTokenCalls = 0;
globalThis.window = makeWindow(async (url, options) => {
  if (url.includes('/api/dashboard4bix/realtime')) return dashboardResponse();
  staleTokenCalls += 1;
  if (options.headers.Auth === 'stale-page-token') {
    return { ok: false, status: 401 };
  }
  return responseFor([{ id: 'fallback-2', status: 'SUCCESS' }], 1);
});
globalThis.window.localStorage.setItem(
  'gamebox-admin-lt-user',
  JSON.stringify({ token: 'stale-page-token', username: 'blake' })
);
const recoveredTokenResult = await executeScan(200, 'fresh-saved-token');
const recoveredUser = JSON.parse(
  globalThis.window.localStorage.getItem('gamebox-admin-lt-user')
);
check(
  recoveredTokenResult.kind === 'ok' && staleTokenCalls === 2,
  'retries the encrypted saved token when the page token is stale'
);
check(
  recoveredTokenResult.restoredPageSession === true
    && recoveredUser.token === 'fresh-saved-token'
    && recoveredUser.username === 'blake',
  'restores the valid token into the existing page session without losing other fields'
);

console.log('All scan-script checks passed');
