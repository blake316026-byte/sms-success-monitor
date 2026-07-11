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
const executeScan = new AsyncFunction('sampleLimit', match[1]);

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

function check(condition, message) {
  if (!condition) {
    throw new Error(`FAIL: ${message}`);
  }
  console.log(`PASS: ${message}`);
}

globalThis.window = makeWindow(async () => {
  throw new Error('fetch should not run without authentication');
}, false);
const unauthenticated = await executeScan(200);
check(unauthenticated.kind === 'auth', 'returns an authentication state when no token is present');

let singlePageCalls = 0;
globalThis.window = makeWindow(async () => {
  singlePageCalls += 1;
  const rows = Array.from({ length: 200 }, (_, index) => ({
    id: `single-${index}`,
    status: index < 120 ? 'SUCCESS' : 'SENT'
  }));
  return responseFor(rows, 5000);
});
const singlePage = await executeScan(200);
check(singlePage.kind === 'ok', 'accepts a successful API response');
check(singlePage.statuses.length === 200, 'returns exactly 200 statuses from a full page');
check(singlePage.statuses.filter((status) => status === 'SUCCESS').length === 120, 'preserves raw SUCCESS statuses');
check(singlePageCalls === 1, 'uses one request when the API accepts pageSize 200');

let cappedPageCalls = 0;
globalThis.window = makeWindow(async (_url, options) => {
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

console.log('All scan-script checks passed');
