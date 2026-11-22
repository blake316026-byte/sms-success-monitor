import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const read=p=>fs.readFileSync(new URL('../'+p,import.meta.url),'utf8');
const source=read('Sources/SMSMonitorApp/TianchengMemoryScript.swift');
const raw=name=>source.match(new RegExp('static let '+name+' = (?:context \\+ )?#"""([\\s\\S]*?)"""#'))[1];
const context=raw('context'), probe=context+raw('probe'), snapshot=context+raw('snapshotGuard')+'return "safe";';
class Storage extends Map {
  getItem(k){return this.get(k)??null;}
  setItem(k,v){this.set(k,String(v));}
}
function fixture(){
  const ss=new Storage(),ls=new Storage(), calls=[], listeners={};
  Object.entries({user:'{"operatorName":"fixture"}',token:'fixture-long-token',tabIsLogin:'1',
    merchantParam:'merchant',merchantPathName:'{"index":"merchant"}',merchants:'[{"merchantCode":"merchant"}]'})
    .forEach(([k,v])=>ss.setItem(k,v));
  ls.setItem('TOKEN','fixture-long-token');ls.setItem('OPERATOR_NAME','fixture');
  const f={ss,ls,calls,listeners,modals:[],code:200,onFetch:()=>{},onJSON:()=>{},
    policy:{expired:false,fixedVerifyIntervalMinutes:240,idleTimeoutMinutes:60,fixedVerifyExpireAt:100,idleExpireAt:200}};
  const win={__smsMemoryActivity:{touched:false},__smsMonitorMemoryCompacted:true};
  f.window=win;
  const ctx={window:win,localStorage:ls,sessionStorage:ss,expectedUsername:'fixture',tiancheng:true,
    location:{origin:'https://fixture.invalid',pathname:'/index'},setTimeout,clearTimeout,AbortController,
    document:{querySelector:()=>null,querySelectorAll:()=>f.modals,addEventListener:(k,fn)=>{listeners[k]=fn;}},
    getComputedStyle:()=>({visibility:'visible'}),fetch:async(url,options)=>{
      calls.push({url,options});f.onFetch();
      assert.equal(options.method,'GET');assert.equal(url,'/tac/api/auth/google/operator-ga-status');
      return {status:f.code,ok:f.code===200,json:async()=>{f.onJSON();return {success:true,value:f.policy};}};
    }};
  f.ctx=vm.createContext(ctx);
  f.run=(body=probe)=>vm.runInContext('(async()=>{'+body+'})()',f.ctx);
  return f;
}
let f=fixture();
assert.equal(await f.run(snapshot),'safe');
assert.equal(await f.run(),'valid');
f.policy.expired=true;assert.equal(await f.run(),'expired');
assert.equal(await f.run(snapshot),null);
for(const k of ['sms-tiancheng-session-attempt-v1','sms-tiancheng-session-manual-v1','sms-tiancheng-login-paused']){
  f=fixture();f.ss.setItem(k,'1');assert.equal(await f.run(),'blocked');assert.equal(f.calls.length,0);
}
for(const k of ['__smsChannelsBusy','__smsProviderManagementBusy','__smsPendingOrdersAbort','__smsPendingAlertsAbort']){
  f=fixture();f.window[k]=true;assert.equal(await f.run(snapshot),null);assert.equal(f.calls.length,0);
}
f=fixture();f.modals=[{getClientRects:()=>[1]}];assert.equal(await f.run(),'blocked');assert.equal(f.calls.length,0);
f=fixture();f.window.__smsMemoryActivity.touched=true;assert.equal(await f.run(snapshot),null);assert.equal(f.calls.length,0);
f=fixture();f.ss.setItem('merchantPathName','{"index":"different"}');assert.equal(await f.run(snapshot),null);assert.equal(f.calls.length,0);
for(const change of [
 f=>f.ls.setItem('TOKEN','different-token'),f=>f.ss.setItem('user','{"operatorName":"other"}'),
 f=>f.ls.setItem('OPERATOR_NAME','other'),f=>f.ss.delete('tabIsLogin')]){
  f=fixture();change(f);assert.equal(await f.run(),'auth');assert.equal(f.calls.length,0);
}
f=fixture();f.onFetch=()=>f.ss.setItem('user','{"operatorName":"other"}');assert.equal(await f.run(),'changed');
f=fixture();f.onJSON=()=>f.window.__smsChannelsBusy=true;assert.equal(await f.run(),'blocked');
f=fixture();f.onJSON=()=>{f.window.__smsMemoryActivity.touched=true;};assert.equal(await f.run(snapshot),null);
for(const code of [401,403,500]){
  f=fixture();f.code=code;assert.equal(await f.run(),code===401?'auth':'unavailable');
}
f=fixture();f.onFetch=()=>{throw Error('timeout')};assert.equal(await f.run(),'unavailable');assert.equal(f.calls.length,1);
f=fixture();f.policy={expired:false};assert.equal(await f.run(),'unavailable');
f=fixture();f.policy.idleTimeoutMinutes=null;f.policy.idleExpireAt=null;assert.equal(await f.run(),'valid');
f=fixture();f.window.__smsMonitorMemoryCompacted=false;assert.equal(await f.run(),'changed');assert.equal(f.calls.length,0);
f=fixture();delete f.window.__smsMemoryActivity;
vm.runInContext(raw('activityObserver'),f.ctx);
f.listeners.input({isTrusted:false});assert.equal(f.window.__smsMemoryActivity.touched,false);
f.listeners.input({isTrusted:true});assert.equal(f.window.__smsMemoryActivity.touched,true);
const notice=({title='域名到期告警 (2026-11-22)',input=false,text='example.invalid 到期',button='关闭'}={})=>({
  getClientRects:()=>[1],textContent:text,
  querySelector:s=>s==='.ant-modal-title'?{textContent:title}:input?{}:null,
  querySelectorAll:()=>[{textContent:button,classList:{contains:()=>false}}]
});
f=fixture();f.ctx.tiancheng=false;f.modals=[notice()];
assert.equal(await f.run(snapshot),'safe');assert.equal(f.calls.length,0,'NPG notice check does not call TC or any write');
for(const options of [{title:'登录申请'},{input:true},{text:'身份验证'},{button:'同意'},{title:'域名到期告警修改配置'}]){
  f=fixture();f.ctx.tiancheng=false;f.modals=[notice(options)];
  assert.equal(await f.run(snapshot),null);assert.equal(f.window.__smsMemorySkipReason,'dialog');
}
f=fixture();f.ctx.tiancheng=false;f.modals=[notice(),{getClientRects:()=>[1]}];
assert.equal(await f.run(snapshot),null,'another security modal still blocks');
f=fixture();f.modals=[notice()];assert.equal(await f.run(snapshot),null,'TC dialogs are never exempted');
const monitor=read('Sources/SMSMonitorApp/MonitorController.swift');
assert.match(monitor,/compactedTianchengSession[\s\S]*checkCompactedTianchengSession/);
assert.match(monitor,/state != "blocked"/);
assert.match(monitor,/guard isMemoryCompacted, !PlatformPageOperationActivity.isInUse\(webView\)/);
assert.match(monitor,/!isMemoryCompacted \|\| compactedTianchengSession/);
console.log('PASS: lightweight TC GET-only verification, expiry, account binding, edited forms, dialogs, operation leases and query preservation');
