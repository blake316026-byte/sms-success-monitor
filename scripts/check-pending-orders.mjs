import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';

const read = p => fs.readFileSync(new URL('../' + p, import.meta.url), 'utf8');
const swift = read('Sources/SMSMonitorApp/PendingOrdersScript.swift');
const blocks = [...swift.matchAll(/#"""([\s\S]*?)"""#/g)].map(x => x[1]);
const script = blocks[0] + blocks[1];
class Storage {
  values = new Map();
  get length() { return this.values.size; }
  key(i) { return [...this.values.keys()][i]; }
  getItem(k) { return this.values.get(k) ?? null; }
  setItem(k, v) { this.values.set(k, String(v)); }
}
export function fixture(family = 'NPG') {
  const ss = new Storage(), ls = new Storage(), calls = [];
  if (family === 'TC') {
    for (const [k, v] of Object.entries({ merchants: [{ merchantCode: 'm', merchantCurrency: 'TLB' }], merchantParam: 'm',
      user: { operatorName: 'fixture' }, token: 'token', tabIsLogin: '1', permission: [20011, 20016, 20020], environment: 'S1' })) ss.setItem(k, typeof v === 'object' ? JSON.stringify(v) : v);
    ls.setItem('TOKEN', 'token'); ls.setItem('operatorCustomization', '{"customTimezone":"Etc/GMT-8"}');
  } else {
    ls.setItem('lt-user', '{"username":"fixture","token":"token","root":false,"resources":["WITHDRAW_RECORD_LIST","WITHDRAW_AUDIT_RECORD_LIST"]}');
    ls.setItem('COUNTRY', 'PH');
  }
  const f = { ss, ls, calls, onFetch() {}, respond: null };
  const fetch = async (input, options) => {
    const url = new URL(input); const body = options.body ? JSON.parse(options.body) : Object.fromEntries(url.searchParams);
    calls.push({ url, body, options }); f.onFetch();
    let p;
    if (url.pathname.endsWith('timezone_with_country')) p = { status: 0, model: 'Asia/Manila' };
    else p = f.respond ? f.respond(body, url) : family === 'TC'
      ? { success: true, totalPageCount: 1, value: [{ id: url.pathname.endsWith('searchPendingApproval') ? 101 : url.pathname.endsWith('searchPending2ndApproval') ? 102 : 103, merchantCode: 'm', status: 'NEW' }] }
      : { status: 0, page: { content: [{ id: 'record-' + body.query.status, withdrawOrderId: 'W-PENDING', status: body.query.status }], totalElements: 1 } };
    return { ok: true, status: 200, json: async () => p };
  };
  const window = { sessionStorage: ss, localStorage: ls, fetch };
  f.ctx = vm.createContext({ window, fetch, location: { origin: 'https://fixture.invalid', pathname: '/31690', hash: '' },
    document: { querySelector: () => null }, getComputedStyle: () => ({ visibility: 'visible' }),
    URL, URLSearchParams, AbortController, setTimeout, clearTimeout, atob, crypto:webcrypto, TextEncoder,
    expectedUsername: 'fixture', allowNPG: true, requestID: 'run', startDate: '2026-10-04', endDate: '2026-10-10' });
  f.run = () => vm.runInContext(`(async () => {${script}})()`, f.ctx);
  return f;
}
let f = fixture(), result = await f.run();
assert.equal(result.kind, 'ok'); assert.equal(result.orders.length, 2);
assert.deepEqual(f.calls.slice(1).map(c => c.body.query.status), ['PENDING', 'ERROR']);
assert.deepEqual(f.calls.slice(1).map(c => c.url.pathname), ['/api/withdraw_audit_record/page', '/api/withdraw_record/page']);
assert.equal(result.orders[0].id, 'W-PENDING', 'use withdrawal order ID, not audit record ID');
assert.equal(result.orders[1].id, 'record-ERROR');
assert.equal(f.calls[1].body.query.countryId, 'PH');
assert.equal(f.calls[1].body.query.invitedCountType, -1);
assert.equal(f.calls[1].body.query.dtCreated.start, Date.parse('2026-10-03T16:00:00Z'));
assert.equal(f.calls[1].body.query.dtCreated.finish, Date.parse('2026-10-10T15:59:59.999Z'));
assert.equal(f.calls[1].options.headers.Auth, 'token');
f = fixture('TC'); result = await f.run();
assert.equal(result.kind, 'ok'); assert.equal(result.orders.length, 3);
assert.deepEqual(f.calls.map(c => c.url.pathname.split('-').at(-1)), ['searchPendingApproval', 'searchPending2ndApproval', 'searchPendingPayment']);
assert(f.calls.every(c => c.options.method === 'GET'));
assert.equal(f.calls[0].body.startDate, '2026-10-03 12:00:00');
assert.equal(f.calls[0].body.endDate, '2026-10-10 11:59:59');
assert.equal(f.calls[0].body.searchDateMode, 'requestTime');
assert.deepEqual(f.calls.map(c => c.body.pid), ['20011', '20016', '20020']);
assert.equal(result.orders[2].status, '支付');
for (const family of ['TC', 'NPG']) {
  f = fixture(family); f.ctx.expectedUsername = 'wrong'; assert.equal((await f.run()).kind, 'error'); assert.equal(f.calls.length, 0);
  f = fixture(family); f.onFetch = () => { f.ls.setItem(family === 'TC' ? 'TOKEN' : 'lt-user', 'rotated'); };
  result = await f.run(); assert.equal(result.kind, 'error'); assert.equal(result.orders.length, 0);
  f = fixture(family); f.ctx.endDate = '2026-02-30'; assert.equal((await f.run()).kind, 'error');
  f = fixture(family); f.respond = () => family === 'TC' ? { success: true, value: [], totalPageCount: 0 } : { status: 0, page: { content: [], totalElements: 0 } };
  result = await f.run(); assert.equal(result.kind, 'ok'); assert.equal(result.orders.length, 0);
  for (const badTotal of [null, undefined, false, -1, 'bad']) {
    f = fixture(family); f.respond = () => family === 'TC' ? { success: true, value: [], totalPageCount: badTotal } : { status: 0, page: { content: [], totalElements: badTotal } };
    assert.equal((await f.run()).kind, 'partial');
  }
}
f = fixture(); f.respond = body => ({ status: 0, page: { totalElements: 3, content: (body.query.pageNo === 1 ? [1,2] : [3]).map(i => ({id:body.query.status+i,withdrawOrderId:'W'+i,status:body.query.status})) } });
result = await f.run(); assert.equal(result.kind, 'ok'); assert.equal(result.orders.length, 6); assert.equal(f.calls.length, 5);
f = fixture(); f.respond = body => ({ status: 0, page: { totalElements: 5, content: [{ id: 'repeat', withdrawOrderId:'repeat-withdrawal', status: body.query.status }] } });
assert.equal((await f.run()).kind, 'partial');
f = fixture(); f.respond = body => body.query.status === 'PENDING' ? { status: 403 } : { status: 0, page: { totalElements: 1, content: [{ id: 'error-order', status: 'ERROR' }] } };
result = await f.run(); assert.equal(result.kind, 'partial'); assert.equal(result.orders.length, 1);
for (const permission of ['WITHDRAW_RECORD_LIST', 'WITHDRAW_AUDIT_RECORD_LIST']) {
  f = fixture(); f.ls.setItem('lt-user', JSON.stringify({username:'fixture',token:'token',root:false,resources:[permission,'WITHDRAW_AUDIT_USER']}));
  result = await f.run(); assert.equal(result.kind,'partial'); assert.equal(result.orders.length,1);
  assert.equal(f.calls.length,2,'skip only the unauthorized group');
  assert.equal(f.calls[1].body.query.status,permission==='WITHDRAW_RECORD_LIST'?'ERROR':'PENDING');
  if(permission==='WITHDRAW_AUDIT_RECORD_LIST')assert.equal(f.calls[1].body.query.invitedCountType,0);
}
f=fixture();f.respond=body=>({status:0,page:{totalElements:1,content:[{id:'audit-id',status:body.query.status}]}});
result=await f.run();assert.equal(result.kind,'partial');assert.match(result.message,/订单号缺失/);
f = fixture('TC'); f.ss.setItem('permission', '[20011]'); result = await f.run();
assert.equal(result.kind, 'partial'); assert.equal(f.calls.length, 1); assert.match(result.message, /无此页签权限/);
f = fixture('TC'); f.respond = () => ({ success: true, totalPageCount: 1, value: [{ id: 9007199254740994 }] });
assert.equal((await f.run()).kind, 'partial');
f = fixture(); await f.run(); f.ctx.contextID = 'run';
assert.equal((await vm.runInContext(`(async () => {${blocks[0] + blocks[2]}})()`, f.ctx)).kind, 'ok');
f.ls.setItem('COUNTRY', 'US');
assert.equal((await vm.runInContext(`(async () => {${blocks[0] + blocks[2]}})()`, f.ctx)).kind, 'error');
assert.doesNotMatch(script, /\/(lock|unlock|approve|re_withdraw|batch_query|make_failed)(?:["'/])/);
console.log('PASS: pending-order status endpoints, pagination, timezone range, account isolation, partial failures, exact IDs and stale navigation');
