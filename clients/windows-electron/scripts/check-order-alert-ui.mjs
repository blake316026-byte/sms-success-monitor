import assert from 'node:assert/strict';
const {chromium}=await import(process.env.SMS_PLAYWRIGHT_MODULE||'playwright-core');
const browser=await chromium.launch({executablePath:process.env.CHROME_PATH||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
try {
  const page=await browser.newPage({viewport:{width:1040,height:720}}),errors=[];
  page.on('pageerror',error=>errors.push(error.message));
  await page.addInitScript(()=>{
    const now=Date.now();
    const state={kind:'pending',start:'2026-11-14',end:'2026-11-20',settings:{auto:true,interval:60},running:false,message:'查询完成',
      platforms:[{id:'fixture',name:'菲律宾测试平台',savedAt:now}],rows:[{id:'W-fixture',platformID:'fixture',platform:'菲律宾测试平台',
        status:'待处理',createdAt:now-1800000,observedAt:now,confirmed:true}]};
    window.alertFixture={settings:{enabled:false,minutes:20,lookbackDays:7,chatID:'',hasToken:false},blocked:false,message:'报警未开启',
      records:[{platform:'菲律宾测试平台',orderID:'W-example-001',at:now,state:'发送待确认'}],
      platforms:[{id:'fixture',name:'菲律宾测试平台',selected:true,message:'已查 1 条 · 待提醒 0 条'},
        {id:'new',name:'新增平台',selected:false,message:'未查询 · 不发送 TG'}]};
    window.reportApi={get:async()=>state,onChange:f=>window.updateFixture=f,configure:async()=>state,fetch:async()=>({}),cancel:async()=>({}),
      alerts:async()=>structuredClone(window.alertFixture),
      selectAlertPlatform:async(id,selected)=>{
        window.lastSelection={id,selected};
        if(window.failSelection)return {ok:false,message:'平台选择保存失败'};
        window.alertFixture.platforms.find(p=>p.id===id).selected=selected;
        return structuredClone(window.alertFixture);
      },saveAlerts:async input=>{
        window.lastAlertInput=input;
        const {token,...settings}=input;window.alertFixture.settings={...settings,hasToken:!!token};
        return window.alertFixture;
      }};
  });
  await page.goto(new URL('../build/reports.html',import.meta.url).href);
  await page.locator('#alerts-open').click();
  await page.waitForSelector('#alerts-rows tr');
  assert.equal(await page.locator('#alerts-minutes').inputValue(),'20');
  assert.equal(await page.locator('#alerts-enabled').isChecked(),false);
  assert.match(await page.locator('#alerts-rows').innerText(),/发送待确认/);
  await page.screenshot({path:'/tmp/sms-alerts-windows-desktop.png'});
  await page.locator('#alerts-minutes').fill('5');
  await page.locator('#alerts-token').fill('123456:'+'x'.repeat(30));
  await page.locator('#alerts-group').fill('-100123456789');
  await page.locator('#alerts-save').click();
  await page.waitForFunction(()=>window.lastAlertInput?.minutes===5);
  assert.equal(await page.locator('#alerts-token').inputValue(),'');
  await page.locator('#alerts-platforms').click();
  assert.match(await page.locator('#alerts-rows').innerText(),/已查 1 条/);
  assert.equal(await page.locator('#alerts-columns th').allTextContents().then(x=>x.join(',')),'TG 报警,平台,查询结果');
  assert.equal(await page.getByRole('checkbox',{name:'菲律宾测试平台 TG 报警',exact:true}).isChecked(),true);
  assert.equal(await page.getByRole('checkbox',{name:'新增平台 TG 报警',exact:true}).isChecked(),false);
  await page.getByRole('checkbox',{name:'菲律宾测试平台 TG 报警',exact:true}).uncheck();
  await page.waitForFunction(()=>window.lastSelection?.selected===false);
  assert.equal(await page.getByRole('checkbox',{name:'菲律宾测试平台 TG 报警',exact:true}).isChecked(),false);
  await page.getByRole('checkbox',{name:'新增平台 TG 报警',exact:true}).check();
  await page.waitForFunction(()=>window.lastSelection?.id==='new'&&window.lastSelection.selected);
  await page.evaluate(()=>{window.failSelection=true;});
  await page.getByRole('checkbox',{name:'新增平台 TG 报警',exact:true}).click();
  await page.waitForSelector('#alerts-error:not(:empty)');
  assert.equal(await page.getByRole('checkbox',{name:'新增平台 TG 报警',exact:true}).isChecked(),true,'failed save restores persisted state');
  await page.evaluate(()=>{window.failSelection=false;});
  await page.screenshot({path:'/tmp/sms-alerts-selection-windows-desktop.png'});
  await page.setViewportSize({width:640,height:650});
  await page.screenshot({path:'/tmp/sms-alerts-windows-narrow.png'});
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
  assert.equal(await page.locator('#alerts-dialog').evaluate(el=>el.scrollWidth>el.clientWidth),false);
  await page.locator('#alerts-token').fill('secret-on-close');
  await page.locator('#alerts-close').click();
  assert.equal(await page.locator('#alerts-token').inputValue(),'');
  assert.equal(await page.locator('#rows tr').count(),1,'settings do not replace the orders view');
  assert.deepEqual(errors,[]);
  console.log('PASS: TG settings dialog, default off, token clearing, records/status tabs, independent order view and desktop/narrow layout');
} finally {await browser.close();}
