import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {EventEmitter} from 'node:events';
import vm from 'node:vm';
import {PendingOrderAlerts,alertEligible,alertDay,ALERT_TTL,defaultAlerts} from './pending-order-alerts.mjs';
import {openAlertStore,telegramSend} from './pending-order-alert-runtime.mjs';
import {queryScripts} from '../scripts/query-scripts.mjs';
import {fixture} from '../../../scripts/check-pending-orders.mjs';

const now=Date.parse('2026-11-20T15:59:00Z');
const settings={...defaultAlerts(),enabled:true,token:'123456:'+ 'x'.repeat(30),chatID:'-100123456789',selectedPlatformIDs:['p']};
function harness(options={}) {
  const h={now,saved:null,sends:[],calls:[],sources:[{id:'p',name:'测试台',url:'https://fixture.invalid/31690',account:'fixture',ready:true}],...options};
  h.row=()=>({id:'order',status:'待处理',createdAt:h.now-1200001,observedAt:h.now});
  h.execute=async(source,key,args)=>{
    h.calls.push(key);
    if(key==='alerts')return {kind:'ok',family:'TC',merchant:'m',country:'',orders:[h.row()],contextID:'run'};
    return {kind:'ok'};
  };
  h.make=(load=()=>h.saved,save=data=>{h.saved=structuredClone(data);})=>new PendingOrderAlerts({
    sources:()=>h.sources,now:()=>h.now,load,save,execute:(...args)=>h.execute(...args),
    send:async(s,text)=>{assert(h.saved.records.some(r=>r.state==='发送中'),'durable reservation must precede network');
      h.sends.push({s,text});return h.delivery||{state:'已发送',messageID:'1'};}});
  h.engine=h.make();return h;
}
const flush=()=>new Promise(resolve=>setImmediate(resolve));
async function cycle(h) {await h.engine.scan(h.sources[0]);await h.engine.drain();}
let h=harness();
h.engine.tick();await flush();assert.equal(h.calls.length,0);assert.equal(h.engine.snapshot().settings.enabled,false);
assert(!JSON.stringify(h.engine.snapshot()).includes('token'));
h.engine.configure(settings);
await cycle(h);assert.equal(h.sends.length,1);assert.equal(h.saved.records[0].state,'已发送');
await cycle(h);assert.equal(h.sends.length,1);
h.engine=h.make();await cycle(h);assert.equal(h.sends.length,1,'restart must not resend');
h.engine.configure({...settings,minutes:1,chatID:'-100987654321'});await cycle(h);assert.equal(h.sends.length,1,'group/threshold changes do not reset daily key');
h.now+=120000;assert.equal(alertDay(h.now),'2026-11-21');await cycle(h);assert.equal(h.sends.length,2,'next Beijing day permits one reminder');
assert.equal(h.saved.records.length,2);h.now=now+ALERT_TTL;h.engine.prune();assert.equal(h.saved.records.length,1,'expire at exactly 24h');
h.now+=120000;h.engine.prune();assert.equal(h.saved.records.length,0);

for(const delivery of [{state:'发送待确认'},{state:'发送失败（当天不重发）'}]) {
  h=harness({delivery});h.engine.configure(settings);await cycle(h);h.engine=h.make();await cycle(h);assert.equal(h.sends.length,1);
}
h=harness();h.engine.configure(settings);await h.engine.scan(h.sources[0]);
h.now+=120001;await h.engine.drain();assert.equal(h.sends.length,0,'stale query is not a notification');
h=harness();h.engine.configure(settings);await h.engine.scan(h.sources[0]);h.sources[0]={...h.sources[0],account:'changed'};
await h.engine.drain();assert.equal(h.sends.length,0);
h=harness();h.engine.configure(settings);await h.engine.scan(h.sources[0]);h.engine.configure({...settings,enabled:false});
await h.engine.drain();assert.equal(h.sends.length,0);
h=harness();h.engine.configure(settings);h.execute=async()=>({kind:'partial',orders:[h.row()]});await cycle(h);assert.equal(h.sends.length,0);
h=harness();h.engine.configure(settings);await h.engine.scan(h.sources[0]);h.execute=async()=>{throw new Error('page lost');};
await h.engine.drain();assert.equal(h.sends.length,0);assert.equal(h.engine.blocked,false,'read failure may be queried again without replay');
h=harness();h.engine.configure(settings);await h.engine.scan(h.sources[0]);h.engine.save=()=>{throw new Error('disk full');};
await h.engine.drain();assert.equal(h.sends.length,0);assert.equal(h.engine.blocked,true);
h=harness();h.engine.configure(settings);await cycle(h);h.now-=120000;h.engine.maintenance=-Infinity;h.engine.tick();assert.equal(h.engine.blocked,true);
h=harness();h.engine=h.make(()=>{throw new Error('bad encryption');});h.engine.tick();assert.equal(h.engine.blocked,true);assert.equal(h.sends.length,0);
h=harness();h.engine.configure(settings);await cycle(h);h.saved.records[0].state='发送中';h.engine=h.make();assert.equal(h.engine.snapshot().records[0].state,'发送待确认');await cycle(h);assert.equal(h.sends.length,1);
h=harness();h.engine.configure(settings);
h.execute=async(source,key)=>key==='alerts'?{kind:'ok',family:'TC',merchant:source.merchant||'m',orders:[h.row()],contextID:'run'}:{kind:'ok'};
await cycle(h);h.sources=[{...h.sources[0],id:'alias'}];h.engine.selectPlatform('alias',true);await cycle(h);assert.equal(h.sends.length,1,'duplicate profile of same merchant shares dedupe');
h.sources=[{...h.sources[0],merchant:'other'}];await cycle(h);assert.equal(h.sends.length,2,'different merchant same order id is distinct');
h=harness();h.engine.configure(settings);h.execute=async(source,key)=>key==='alerts'
  ?{kind:'ok',family:'TC',merchant:'m',orders:Array.from({length:25},(_,i)=>({...h.row(),id:'order'+i})),contextID:'run'}:{kind:'ok'};
await h.engine.scan(h.sources[0]);await h.engine.drain();assert.equal(h.saved.records.length,10);assert(h.sends[0].text.length<4096);
await h.engine.drain();await h.engine.drain();assert.equal(h.saved.records.length,25);assert.equal(h.sends.length,3);
assert(h.sends.every(s=>!s.text.includes(settings.token)));
const row={id:'o',status:'待处理',createdAt:now-1200000,observedAt:now};
assert.equal(alertEligible(row,now,20),false);
assert.equal(alertEligible({...row,createdAt:row.createdAt-1},now,20),true);
for(const patch of [{createdAt:null},{observedAt:now-120001},{createdAt:now+1},{observedAt:now+1},{status:'已放款'},{createdAt:true}])assert.equal(alertEligible({...row,...patch},now,20),false);

h=harness();h.engine.configure({...settings,selectedPlatformIDs:[]});await cycle(h);assert.equal(h.sends.length,0);
h.engine.selectPlatform('p',true);await cycle(h);assert.equal(h.sends.length,1);
h.engine.selectPlatform('p',false);h.engine.selectPlatform('p',true);await cycle(h);assert.equal(h.sends.length,1,'reselection keeps dedupe');
h.saved.version=1;delete h.saved.settings.selectedPlatformIDs;const oldRecords=structuredClone(h.saved.records);
h.engine=h.make();assert.equal(h.saved.version,2);assert.equal(h.engine.isSelected('p'),true);assert.deepEqual(h.saved.records,oldRecords);
assert.equal(h.saved.settings.token,settings.token);assert.equal(h.saved.settings.chatID,settings.chatID);
h.sources.push({...h.sources[0],id:'new'});assert.equal(h.engine.isSelected('new'),false);
h.engine.selectPlatform('p',false);h.engine=h.make();assert.deepEqual(h.saved.settings.selectedPlatformIDs,[],'empty selection survives restart');
assert.throws(()=>h.engine.selectPlatform('missing',true));
h=harness();h.engine.configure(settings);await h.engine.scan(h.sources[0]);h.engine.selectPlatform('p',false);
await h.engine.drain();assert.equal(h.sends.length,0,'uncheck clears queued reminders');
h=harness();h.engine.configure(settings);await h.engine.scan(h.sources[0]);
let validate;h.execute=async()=>new Promise(resolve=>{validate=resolve;});const pending=h.engine.drain();
h.engine.selectPlatform('p',false);validate({kind:'ok'});await pending;
assert.equal(h.sends.length,0,'uncheck during preflight must stop submission');assert.equal(h.saved.records.length,0);
h=harness();h.engine.configure(settings);await h.engine.scan(h.sources[0]);
h.engine.save=()=>{throw new Error('disk full');};assert.throws(()=>h.engine.selectPlatform('p',false));
await h.engine.drain();assert.equal(h.engine.blocked,true);assert.equal(h.sends.length,0);
for(const selection of [null,['p','p'],[7]]) {
  h=harness();const data={...h.saved,settings:{...settings,selectedPlatformIDs:selection}};
  h.engine=h.make(()=>data);assert.equal(h.engine.blocked,true);
}
const scripts=queryScripts();
for(const family of ['TC','NPG']) {
  const f=fixture(family);
  f.ctx.window.__smsPendingOrdersContext={id:'ui-context'};f.ctx.window.__smsPendingOrdersRun='ui-run';
  const result=await vm.runInContext('(async()=>{'+scripts.alerts+'})()',f.ctx);
  assert.equal(result.kind,'ok');assert.equal(f.ctx.window.__smsPendingOrdersContext.id,'ui-context');
  assert.equal(f.ctx.window.__smsPendingOrdersRun,'ui-run');
  f.ctx.contextID='run';assert.equal((await vm.runInContext('(async()=>{'+scripts.alertValidate+'})()',f.ctx)).kind,'ok');
  f.ls.setItem(family==='TC'?'TOKEN':'COUNTRY','changed');
  assert.equal((await vm.runInContext('(async()=>{'+scripts.alertValidate+'})()',f.ctx)).kind,'error');
  assert(f.calls.every(c=>['/api/auth/timezone_with_country','/api/withdraw_audit_record/page','/api/withdraw_record/page',
    '/tac/api/relay/get/mcs-v3-player-withdraw-searchPendingApproval','/tac/api/relay/get/mcs-v3-player-withdraw-searchPending2ndApproval',
    '/tac/api/relay/get/mcs-v3-player-withdraw-searchPendingPayment'].includes(c.url.pathname)));
}

const directory=fs.mkdtempSync(path.join(os.tmpdir(),'alerts-store-'));
const safe={isEncryptionAvailable:()=>true,encryptString:s=>Buffer.from('encrypted:'+s),decryptString:b=>b.toString().slice(10)};
try {
  const store=openAlertStore(directory,safe);store.save({fixture:true});assert.deepEqual(store.load(),{fixture:true});
  assert.throws(()=>openAlertStore(directory,safe));store.close();
  const next=openAlertStore(directory,safe);assert.deepEqual(next.load(),{fixture:true});next.close();
  assert(!fs.readdirSync(path.join(directory,'withdrawal-alerts-v1')).some(name=>name.endsWith('.tmp')));
} finally{fs.rmSync(directory,{recursive:true,force:true});}

for(const [status,body,expected] of [[200,{ok:true,result:{message_id:12}},'已发送'],[429,{ok:false},'发送失败（当天不重发）'],
  [500,{ok:false},'发送待确认'],[302,{},'发送待确认'],[200,{ok:true},'发送待确认']]) {
  let count=0;
  const result=await telegramSend(settings,'test',(options,callback)=>{
    count++;assert.equal(options.hostname,'api.telegram.org');assert.equal(options.method,'POST');
    const req=new EventEmitter();req.end=()=>queueMicrotask(()=>{const response=new EventEmitter();response.statusCode=status;callback(response);
      response.emit('data',Buffer.from(JSON.stringify(body)));response.emit('end');});req.destroy=()=>{};return req;
  });
  assert.equal(result.state,expected);assert.equal(count,1);
}
console.log('PASS: TG defaults, daily dedupe/restart, 24h retention, ambiguous send, freshness, scope, batches, read-only isolation, encrypted-store lock and no resend');
