import assert from 'node:assert/strict';
import vm from 'node:vm';
import fs from 'node:fs';
import {TianchengAuthentication, mayMaintainAuthentication, currentTotpExpression, withDeadline} from './background-authentication.mjs';

const profile = {username: 'fixture', password: 'fixture', totpSecret: 'fixture', autoLoginEnabled: true};
const input = {profile, configuredURL: 'https://fixture.invalid/index', currentURL: 'https://fixture.invalid/login'};
assert.equal(mayMaintainAuthentication(input), true);
for (const override of [{blocked:true},{loading:true},{currentURL:'https://other.invalid/login'},
  {profile:{...profile,autoLoginEnabled:false}},{profile:null}]) assert.equal(mayMaintainAuthentication({...input,...override}),false);
let clock = 60001, timestamp;
const context = {Date:{now:()=>clock},setTimeout:(fn,delay)=>{clock+=delay;fn();},
  localAutomationRuntime:{generateTotp:async(_,time)=>{timestamp=time;return '123456';}}};
const code = currentTotpExpression('fixture',30000);
clock = 116000;
assert.equal(await vm.runInNewContext(code,context),'123456');
assert.equal(timestamp,151000);
assert.throws(()=>currentTotpExpression('fixture',Infinity));
await assert.rejects(withDeadline(()=>new Promise(()=>{}),5),/timed out/);

let now=0,kind='password',attempts=[],messages=[],result={submitted:false,retryable:true},active=true;
const auth=new TianchengAuthentication({profile:()=>profile,valid:()=>active,now:()=>now,timeoutMs:10,
  generateCode:async()=> '123456',changed:(...m)=>messages.push(m),
  call:async(action)=>{if(action==='snapshot')return {kind};attempts.push(action);return result;}});
await auth.tick();assert.equal(auth.paused,false);assert.equal(auth.stage,'');
now+=5000;result={submitted:true};await auth.tick();assert.equal(auth.stage,'password');
now+=5000;await auth.tick();assert.equal(attempts.length,2,'Do not repeat password submission');
kind='totp';now+=5000;await auth.tick();assert.equal(auth.stage,'totp');
now+=5000;await auth.tick();assert.equal(attempts.length,3,'Do not repeat OTP submission');
kind='authenticated';now+=5000;await auth.tick();assert.equal(auth.stage,'');assert.equal(messages.at(-1)[1],'天成已登录');
kind='password';now+=15000;result=null;await auth.tick();assert.equal(auth.paused,true);
now+=5000;await auth.tick();assert.equal(attempts.length,4,'Unknown submission must not replay');
await auth.reset();kind='manual';now+=5000;await auth.tick();assert.equal(auth.paused,true);
const count=attempts.length;kind='password';now+=5000;await auth.tick();assert.equal(attempts.length,count);

let pending;
const timed=new TianchengAuthentication({profile:()=>profile,valid:()=>true,now:()=>now,timeoutMs:5,
  generateCode:async()=>'',changed:()=>{},call:()=>new Promise(r=>{pending=r;})});
await timed.tick();assert.equal(timed.busy,false);assert.equal(timed.paused,false,'Only a read timed out');
pending({kind:'password'});assert.equal(timed.stage,'');
now+=5000;const running=timed.tick();await new Promise(r=>setTimeout(r,1));timed.stop();pending({kind:'password'});await running;
assert.equal(timed.stage,'');assert.equal(timed.busy,false);

const main=fs.readFileSync(new URL('./main.mjs',import.meta.url),'utf8');
assert.match(main,/authenticationTimer = setInterval[\s\S]*maintainAuthentication\(id\)[\s\S]*5000/);
assert.match(main,/backgroundThrottling: false/);
assert.match(main,/const code = await generateCurrentTotp\(secret, offsetMs\)/);
console.log('PASS: background auth independent of monitoring, origin/manual guards, current-clock OTP, transient form retry, uncertain-submit no replay, deadline and cancellation');

let periodicKind='required',periodicCalls=[],currentProfile=profile,generated=0;
let periodicNow=100000;
const periodic=new TianchengAuthentication({profile:()=>currentProfile,valid:()=>true,now:()=>periodicNow,
  generateCode:async()=>{generated++;return '123456';},changed:(...message)=>messages.push(message),
  call:async()=>({kind:'authenticated'}),sessionCall:async(action,args)=>{
    periodicCalls.push({action,args});
    if(action==='snapshot')return {kind:periodicKind,challenge:'fixture-challenge'};
    if(action==='submit'){periodicKind='manual';throw Error('Lost callback after clicking');}
  }});
await periodic.tick();periodicNow+=10000;await periodic.tick();
assert.equal(periodicCalls.filter(x=>x.action==='submit').length,1);
assert.equal(generated,1);assert.equal(messages.at(-1)[0],'auth');
for(const kind of ['operation','unavailable','waiting','manual']) {
  periodicKind=kind;periodicNow+=40000;await periodic.tick();
  assert.equal(periodicCalls.filter(x=>x.action==='submit').length,1,'Blocked state must not submit or resume a write');
}
periodicKind='verified';periodicNow+=40000;await periodic.tick();assert.equal(messages.at(-1)[0],'disabled');
periodicKind='required';periodicNow+=40000;
periodic.generateCode=async()=>{currentProfile={...profile,username:'other'};return '123456';};
await periodic.tick();assert.equal(periodicCalls.filter(x=>x.action==='submit').length,1,'Changed account must not receive OTP');
await periodic.reset();assert.equal(periodicCalls.at(-1).action,'reset');
console.log('PASS: periodic GA controller only submits proven session challenge, reads after uncertainty, never handles business gates, checks saved-account changes and resets explicitly');
