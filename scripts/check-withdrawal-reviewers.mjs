import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { fixture } from './check-pending-orders.mjs';

const source = name => fs.readFileSync(new URL('../Sources/SMSMonitorApp/' + name + '.swift', import.meta.url), 'utf8');
const block = s => [...s.matchAll(/#"""([\s\S]*?)"""#/g)].map(m => m[1]);
const shared = block(source('PendingOrdersScript'));
const query = shared[0] + block(source('WithdrawalReviewersScript'))[0];
function setup(family) {
  const f = fixture(family);
  f.ctx.startDate = f.ctx.endDate = '2026-10-10';
  f.ctx.requiredNPGPermission = 'WITHDRAW_AUDIT_RECORD_LIST';
  if (family === 'NPG') f.ls.setItem('lt-user', JSON.stringify({username:'fixture',token:'token',resources:['WITHDRAW_AUDIT_RECORD_LIST']}));
  f.run = () => vm.runInContext(`(async()=>{${query}})()`, f.ctx);
  return f;
}
let f = setup('NPG');
f.respond = (body, url) => url.pathname === '/api/account/accounts' ? {status:0,list:[{id:'1',name:'alice'},{id:'2',name:'bob'}]}
  : {status:0,page:{totalElements:body.query.autherId ? body.query.autherId === '1' ? 113 : 207 : 3,
    content:body.query.autherId ? [{id:'count'}] : body.query.pageNo === 1 ? [{id:'a',autherId:'1'},{id:'b',autherId:'1'}] : [{id:'c',autherId:'2'}]}};
let r = await f.run();
assert.equal(r.platformTotal,3);
assert.equal(r.kind,'ok'); assert.deepEqual(JSON.parse(JSON.stringify(r.reviewers)),[{id:'1',name:'alice',count:113},{id:'2',name:'bob',count:207}]);
assert(f.calls.filter(c=>c.body.query).every(c=>c.body.query.dtCreated.start===Date.parse('2026-10-09T16:00:00Z')));
assert(f.calls.filter(c=>c.body.query).every(c=>c.url.pathname==='/api/withdraw_audit_record/page'));
f.ctx.reviewerQuery=true; f.ctx.contextID='run';
assert.equal((await vm.runInContext(`(async()=>{${shared[0]+shared[2]}})()`,f.ctx)).kind,'ok');
f.ctx.window.__smsReviewerContext=null;
assert.equal((await vm.runInContext(`(async()=>{${shared[0]+shared[2]}})()`,f.ctx)).kind,'ok');
assert.doesNotMatch(f.ss.getItem('__smsReviewerContext'),/"token"|alice|fixture/);
f.ls.setItem('COUNTRY','US');
assert.equal((await vm.runInContext(`(async()=>{${shared[0]+shared[2]}})()`,f.ctx)).kind,'error');
f.ls.setItem('COUNTRY','PH');
f.ctx.contextID='different'; assert.equal((await vm.runInContext(`(async()=>{${shared[0]+shared[2]}})()`,f.ctx)).kind,'error');
f = setup('TC');
f.respond = body => ({success:true,totalPageCount:body.reviewOperator ? body.reviewOperator==='alice'?9:7 : 2,value:body.reviewOperator ? [] : [
  {id:101,merchantCode:'m',approveAudit:{lastUpdatedBy:'alice'},paidAudit:{lastUpdatedBy:'alice'}},
  {id:102,merchantCode:'m',reviewAudit:{lastUpdatedBy:'bob'},paidAudit:{lastUpdatedBy:'THIRD_PARTY'}}]});
r=await f.run(); assert.equal(r.kind,'ok'); assert.deepEqual(JSON.parse(JSON.stringify(r.reviewers)),[{id:'alice',name:'alice',count:9},{id:'bob',name:'bob',count:7}]);
assert(f.calls.every(c=>c.body.searchDateMode==='requestTime' && c.url.pathname==='/tac/api/relay/get/mcs-v3-player-withdraw-search'));
assert.equal(f.calls[0].body.startDate,'2026-10-09 12:00:00');
assert.equal(f.calls[0].body.endDate,'2026-10-10 11:59:59');
for(const family of ['NPG','TC']) {
  f=setup(family);f.ctx.totalsOnly=true;
  f.respond=()=>family==='NPG'?{status:0,page:{content:[],totalElements:355}}:{success:true,value:[],totalPageCount:2121};
  r=await f.run();assert.equal(r.kind,'ok');assert.equal(r.platformTotal,family==='NPG'?355:2121);
  assert.equal(f.calls.filter(c=>Number(c.body?.pageSize ?? c.body?.query?.pageSize)===1).length,1);
  assert.equal(r.reviewers,undefined);
  f=setup(family);f.ctx.expectedUsername='wrong';assert.equal((await f.run()).kind,'error');assert.equal(f.calls.length,0);
  f=setup(family);f.onFetch=()=>{f.ctx.window.__smsReviewerRun='cancelled'};assert.equal((await f.run()).kind,'error');
  f=setup(family);f.respond=()=>family==='NPG'?{status:0,page:{content:[],totalElements:0}}:{success:true,value:[],totalPageCount:0};
  r=await f.run();assert.equal(r.kind,'ok');assert.equal(r.reviewers.length,0);
  f=setup(family);f.respond=()=>family==='NPG'?{status:0,page:{content:[{id:'same',autherId:'a'}],totalElements:100}}:{success:true,value:[{id:'same'}],totalPageCount:100};
  r=await f.run();assert.equal(r.kind,'error');assert.equal(r.reviewers.length,0);assert.match(r.message,/分页/);
}
f=setup('NPG');f.ls.setItem('lt-user',JSON.stringify({username:'fixture',token:'token',resources:['WITHDRAW_RECORD_LIST']}));assert.equal((await f.run()).kind,'error');assert.equal(f.calls.length,0);
assert.doesNotMatch(query,/\/(?:make_success|make_failed|batch_make|approve|lock|paidWithdraw)/);
const navigationContext = shared[0] + block(source('WithdrawalReviewersScript'))[1];
for (const family of ['NPG','TC']) {
  f=setup(family); if(family==='TC') f.ss.setItem('permission',JSON.stringify([20009]));
  const prepare=()=>vm.runInContext(`(async()=>{${navigationContext}})()`,f.ctx);
  assert.equal((await prepare()).kind,'ok'); assert.equal(f.calls.length,0);
  f.ctx.reviewerQuery=true;f.ctx.contextID='run';
  assert.equal((await vm.runInContext(`(async()=>{${shared[0]+shared[2]}})()`,f.ctx)).kind,'ok');
  f.ctx.expectedUsername='other';assert.equal((await prepare()).kind,'error');assert.equal(f.calls.length,0);
}
f=setup('TC');f.ss.setItem('permission',JSON.stringify([20011]));
assert.equal((await vm.runInContext(`(async()=>{${navigationContext}})()`,f.ctx)).kind,'error');
console.log('PASS: manual reviewer aggregation, authoritative filtered totals, dates, permission separation, pagination, cancellation and context isolation');
