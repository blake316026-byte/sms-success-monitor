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
      origin: 'https://bills02-otp.local.sms-monitor.invalid'
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
        model: {
          chart: [{ rechargeSuccAmount: 706751.7, withdrawSuccAmount: 511000 }],
          today: { rechargeSuccAmount: rechargeAmount, withdrawSuccAmount: withdrawAmount }
        }
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
check(singlePageCalls === 1, 'does not issue a finance request during an SMS scan');
check(
  Number.isFinite(singlePageQuery.ddCreated.start)
    && Number.isFinite(singlePageQuery.ddCreated.finish)
    && singlePageQuery.ddCreated.finish > singlePageQuery.ddCreated.start,
  'queries the same recent creation-date window used by the SMS record page'
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
  fallbackTokenResult.tokenSource === 'fallback'
    && fallbackTokenResult.restoredPageSession === true
    && JSON.parse(globalThis.window.localStorage.getItem('lt-user')).token === 'saved-token',
  'creates a page session when the encrypted saved token is still valid'
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
  recoveredTokenResult.kind === 'auth' && recoveredTokenResult.manualOnly && staleTokenCalls === 1,
  'does not substitute a saved account when the page token expires'
);
check(
  recoveredUser.token === 'stale-page-token'
    && recoveredUser.username === 'blake',
  'does not overwrite the current page account with a different saved token'
);

console.log('All scan-script checks passed');
