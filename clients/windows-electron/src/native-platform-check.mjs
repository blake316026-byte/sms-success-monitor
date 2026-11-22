import {BrowserWindow,WebContentsView} from 'electron';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import {PlatformMemory} from './platform-memory.mjs';
import {DetachedPlatforms} from './detached-platforms.mjs';
import {TianchengAuthentication} from './background-authentication.mjs';

export async function nativePlatformCheck({scripts,directory,loginSource,sessionSource,npgSource}){
  let expired=false,verifications=0,reads=0,loads=0,forbidden=0,now=100000,active=false,busy=false,family='TC';
  const tcSetup=`
    window.__tacLoader={showError(){},waitForThemeRetry(){}};
    for(const [k,v] of Object.entries({token:'fixture-platform-token',tabIsLogin:'1',user:JSON.stringify({operatorName:'fixture'}),
      merchantParam:'fixture-merchant',merchants:JSON.stringify([{merchantCode:'fixture-merchant',merchantCurrency:'PHP'}]),
      permission:'[31711]',platform:'B2C',environment:'TCG1',preserved:'original-session'}))sessionStorage.setItem(k,v);
    localStorage.setItem('TOKEN','fixture-platform-token');localStorage.setItem('OPERATOR_NAME','fixture');
    localStorage.setItem('operatorCustomization',JSON.stringify({customTimezone:'Etc/GMT-8'}));`;
  const server=http.createServer((req,res)=>{
    if(req.url==='/fixture/verify'&&req.method==='POST'){verifications++;expired=false;res.end('{}');return;}
    if(req.method!=='GET'){forbidden++;res.writeHead(405).end();return;}
    if(req.url.startsWith('/tac/api/auth/google/operator-ga-status')){
      reads++;res.setHeader('Content-Type','application/json');res.end(JSON.stringify({success:true,value:{expired,
        fixedVerifyIntervalMinutes:240,idleTimeoutMinutes:60,fixedVerifyExpireAt:1000,idleExpireAt:1000}}));return;
    }
    if(req.url.startsWith('/tac/api/relay/get/ods-report-profitloss-summary-get')){
      res.setHeader('Content-Type','application/json');res.end(JSON.stringify({success:true,value:{deposit:1234.5,withdraw:678}}));return;
    }
    loads++;res.setHeader('Set-Cookie','fixture=retained; Path=/; SameSite=Lax');res.setHeader('Content-Type','text/html');
    const ga=expired?`<div class="ant-modal-wrap" style="position:fixed;inset:0;z-index:2002"><div class="ga-verify-modal"><div class="ga-verify-hint">GA: 240 minutes, idle 60 minutes</div>${'<input maxlength="1">'.repeat(6)}<div class="ant-modal-footer"><button class="ant-btn-primary" onclick="fetch('/fixture/verify',{method:'POST'}).then(()=>this.closest('.ant-modal-wrap').remove())">Verify</button></div></div></div>`:'';
    const setup=req.url.startsWith('/npg')?`sessionStorage.clear();localStorage.clear();sessionStorage.setItem('lt-user',JSON.stringify({username:'fixture',token:'npg-fixture-token',root:true}));sessionStorage.setItem('COUNTRY','PH');`:tcSetup;
    res.end(`<!doctype html><meta charset="utf-8"><style>body{margin:0;font:14px system-ui}#scroll{height:420px;overflow:auto}#inside{height:1800px;background:#e7f4ee;padding:16px}</style><script>${setup}
      window.heavyFixture=new Array(100000).fill('heavy-view');window.fixtureDocument=crypto.randomUUID();</script>
      <input id="draft" value="saved"><div id="scroll"><div id="inside">Local platform fixture</div></div>${ga}`);
  });
  await new Promise(r=>server.listen(0,'127.0.0.1',r));
  const origin=`http://127.0.0.1:${server.address().port}`;
  const main=new BrowserWindow({show:false,width:1100,height:760,webPreferences:{sandbox:true,contextIsolation:true}});
  const view=new WebContentsView({webPreferences:{sandbox:true,contextIsolation:true,backgroundThrottling:false}});
  const page={id:'native-fixture',name:'Reference fixture',url:origin+'/index',view},pages=new Map([[page.id,page]]);
  const profile={username:'fixture',password:'fixture-only',totpSecret:'JBSWY3DPEHPK3PXP',autoLoginEnabled:true};
  let detached;
  const memory=new PlatformMemory({pages,scripts,active:()=>active||detached?.active(page.id),busy:()=>busy,profile:()=>profile,
    family:()=>family,canSuspend:()=>true,now:()=>now,delay:1});memory.attach(page);
  const run=code=>view.webContents.executeJavaScript(code);
  const attach=()=>{main.contentView.addChildView(view);view.setBounds({x:0,y:48,width:1100,height:712});};
  try{
    await main.loadURL('data:text/html,<title>Lifecycle fixture</title><h3>Local fixture</h3>');
    attach();await view.webContents.loadURL(page.url);now+=10;
    await memory.withLease(page.id,async()=>{await memory.tick(page.id);assert.equal(memory.compacted(page.id),false);});
    memory.touch(page.id);await memory.tick(page.id);assert.equal(memory.compacted(page.id),false);
    await view.webContents.loadURL(page.url);now+=10;
    await run("sessionStorage.setItem('merchantPathName',JSON.stringify({index:'different-merchant'}))");
    await memory.tick(page.id);assert.equal(memory.compacted(page.id),false);
    await run("sessionStorage.removeItem('merchantPathName')");
    await memory.tick(page.id);assert.equal(memory.compacted(page.id),true,'inactive page did not compact');
    assert.equal(await run('location.origin'),origin);
    assert.equal(await run("sessionStorage.getItem('preserved')"),'original-session');
    assert.equal(await run("localStorage.getItem('TOKEN')"),'fixture-platform-token');
    assert.ok((await view.webContents.session.cookies.get({url:origin})).some(c=>c.name==='fixture'&&c.value==='retained'));
    assert.equal(await run('typeof heavyFixture'),'undefined','heavy document survived compaction');
    now+=31000;await memory.tick(page.id);assert.equal(memory.compacted(page.id),true,'valid session unnecessarily woke');
    expired=true;now+=31000;await memory.tick(page.id);assert.equal(memory.compacted(page.id),false,'periodic GA did not wake background page');
    assert.equal(view.webContents.getURL(),page.url);assert.equal(active,false);
    const call=(action,args)=>run(`(async()=>{${loginSource}\nreturn await smsTianchengLogin[${JSON.stringify(action)}](${JSON.stringify(args)});})()`);
    const sessionCall=(action,args)=>run(`(async()=>{${loginSource}\n${sessionSource}\nreturn await smsTianchengSession[${JSON.stringify(action)}](${JSON.stringify(args)});})()`);
    const auth=new TianchengAuthentication({call,sessionCall,profile:()=>profile,valid:()=>true,now:()=>now,
      generateCode:async()=> '123456',changed:()=>{}});
    await auth.tick();await new Promise(r=>setTimeout(r,200));now+=16000;await auth.tick();auth.stop();
    assert.equal(verifications,1,'hidden restored page did not verify exactly once');assert.equal(expired,false);
    assert.ok(reads>=3);assert.equal(forbidden,0);
    active=true;
    await run("document.querySelector('#draft').value='unsaved brand text';document.querySelector('#scroll').scrollTop=320;window.history.pushState({},'', '/index#draft');");
    const documentID=await run('fixtureDocument'),wcID=view.webContents.id,history=view.webContents.navigationHistory.getAllEntries(),beforeLoads=loads;
    detached=new DetachedPlatforms({pages,mainWindow:()=>main,memory,busy:()=>busy,scripts,directory,metadata:()=>({country:'PH'}),
      changed:()=>{},removeMain:()=>main.contentView.removeChildView(view),returned:attach});
    detached.install();
    busy=true;assert.equal(await detached.detach(page.id),false);busy=false;
    assert.equal(await detached.detach(page.id),true,'detach failed');
    assert.equal(view.webContents.id,wcID);assert.equal(await run('fixtureDocument'),documentID);
    assert.equal(await run("document.querySelector('#draft').value"),'unsaved brand text');
    assert.equal(await run("document.querySelector('#scroll').scrollTop"),320);
    assert.deepEqual(view.webContents.navigationHistory.getAllEntries(),history);assert.equal(loads,beforeLoads);
    const w=detached.windows.get(page.id).window;
    await w.webContents.executeJavaScript(`document.querySelector('#name').textContent='Reference fixture';document.querySelector('#country').textContent='PH'`);
    await new Promise(r=>setTimeout(r,300));
    assert.ok(w.contentView.children.includes(view));assert.equal(view.getVisible(),true);assert.ok(view.getBounds().height>400);
    if(process.env.SMS_DISTRIBUTION_TEST_DIR){
      const capture=async wc=>{let error;for(let i=0;i<4;i++){try{return await wc.capturePage(undefined,{stayHidden:false,stayAwake:true});}catch(e){error=e;w.show();w.focus();await new Promise(r=>setTimeout(r,300));}}throw error;};
      const header=await capture(w.webContents),content=await capture(view.webContents);
      assert.ok(!content.isEmpty()&&content.getSize().height>400);
      const pixels=content.toBitmap();let colored=0;for(let i=0;i<pixels.length;i+=4)if(pixels[i]!==pixels[i+1]||pixels[i+1]!==pixels[i+2])colored++;
      assert.ok(colored>10000,'detached content is blank');
      fs.writeFileSync(path.join(process.env.SMS_DISTRIBUTION_TEST_DIR,'detached-header.png'),header.toPNG());
      fs.writeFileSync(path.join(process.env.SMS_DISTRIBUTION_TEST_DIR,'detached-content.png'),content.toPNG());
    }
    assert.equal(await w.webContents.executeJavaScript("window.detachedApi.command('return')"),true);assert.equal(view.webContents.id,wcID);
    assert.equal(await run("document.querySelector('#draft').value"),'unsaved brand text');
    assert.equal(await detached.detach(page.id),true);detached.windows.get(page.id).window.close();
    for(let i=0;i<100&&(detached.windows.size||detached.moving.size);i++)await new Promise(r=>setTimeout(r,50));
    assert.equal(detached.windows.size,0,'close did not return the original page');assert.equal(pages.size,1);
    assert.equal(await run("sessionStorage.getItem('preserved')"),'original-session');assert.equal(loads,beforeLoads);
    assert.equal(forbidden,0);assert.equal(verifications,1);
    family='NPG';active=false;await view.webContents.loadURL(origin+'/npg');now+=61000;
    for(let i=0;i<100&&view.webContents.isLoadingMainFrame();i++)await new Promise(r=>setTimeout(r,20));
    await memory.tick(page.id);assert.equal(memory.compacted(page.id),true,'NPG did not compact: '+JSON.stringify({state:memory.state(page.id),active:detached.active(page.id),now,guard:await memory.script(page,'memorySnapshot',{tiancheng:false}).catch(e=>String(e))}));
    assert.equal(await run("JSON.parse(sessionStorage.getItem('lt-user')).token"),'npg-fixture-token');
    now+=121000;await memory.tick(page.id);assert.equal(memory.compacted(page.id),false,'NPG background authentication wake did not run');
    assert.equal(view.webContents.getURL(),origin+'/npg');assert.equal(forbidden,0);
  }finally{
    detached?.dispose();main.contentView.removeChildView(view);view.webContents.close();main.destroy();
    server.closeAllConnections();await new Promise(r=>server.close(r));
  }
}
