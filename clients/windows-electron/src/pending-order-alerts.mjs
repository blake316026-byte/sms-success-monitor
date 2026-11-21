import crypto from 'node:crypto';

export const ALERT_TTL=86400000, ALERT_FRESHNESS=120000;
export const alertDay=now=>new Date(now+8*3600000).toISOString().slice(0,10);
export const defaultAlerts=()=>({enabled:false,minutes:20,lookbackDays:7,token:'',chatID:'',selectedPlatformIDs:[]});
export const alertKey=(scope,id,now)=>crypto.createHash('sha256').update(JSON.stringify([scope,id,alertDay(now)])).digest('hex');
const clean=value=>String(value||'').replace(/[\p{Cc}\u202a-\u202e\u2066-\u2069]/gu,'').slice(0,90);
const display=now=>new Date(now+8*3600000).toISOString().slice(0,19).replace('T',' ');
const sourceScope=s=>JSON.stringify([s.id,s.url,s.account||'']);
export function validateAlerts(s) {
  if(s.selectedPlatformIDs!==undefined&&(!Array.isArray(s.selectedPlatformIDs)||s.selectedPlatformIDs.length>10000
    ||new Set(s.selectedPlatformIDs).size!==s.selectedPlatformIDs.length
    ||!s.selectedPlatformIDs.every(id=>typeof id==='string'&&id.length>0&&id.length<=512)))throw new Error('报警平台选择格式无效');
  if(typeof s.enabled!=='boolean'||!Number.isInteger(s.minutes)||s.minutes<1||s.minutes>10080
    ||!Number.isInteger(s.lookbackDays)||s.lookbackDays<1||s.lookbackDays>30)throw new Error('报警分钟数须为 1–10080，查询天数须为 1–30');
  if(typeof s.token!=='string'||typeof s.chatID!=='string'||s.token.length>200||s.chatID.length>30)throw new Error('报警设置格式错误');
  if(s.enabled&&(!/^\d{5,20}:[A-Za-z0-9_-]{20,100}$/.test(s.token)||!/^-[0-9]{5,20}$/.test(s.chatID)))throw new Error('请填写有效的机器人 Token 和群 ID（负数）');
}
export function alertEligible(row,now,minutes) {
  return typeof row.id==='string'&&row.id.length>0&&row.id.length<=160
    &&['待处理','待审核','支付','放款异常'].includes(row.status)
    &&Number.isSafeInteger(row.createdAt)&&row.createdAt>=946684800000&&row.createdAt<4102444800000
    &&Number.isSafeInteger(row.observedAt)&&row.createdAt<=row.observedAt&&row.observedAt<=now
    &&now-row.observedAt<=ALERT_FRESHNESS&&now-row.createdAt>minutes*60000;
}

export class PendingOrderAlerts {
  constructor({sources,execute,load,save,send,now=Date.now}) {
    Object.assign(this,{sources,execute,save,send,now});
    this.data={version:2,settings:defaultAlerts(),records:[],lastClock:0};
    this.active=new Set();this.due=new Map();this.statuses=new Map();this.queue=[];this.generation=0;
    this.sending=false;this.nextSend=0;this.maintenance=-Infinity;this.blocked=false;this.stopped=false;this.message='报警未开启';
    try {
      const loaded=load();
      if(loaded) {
        if(![1,2].includes(loaded.version)||!Array.isArray(loaded.records)||!Number.isFinite(loaded.lastClock)
          ||(loaded.version===2&&!Array.isArray(loaded.settings?.selectedPlatformIDs)))throw new Error('Invalid store');
        validateAlerts(loaded.settings);
        if(!loaded.records.every(r=>typeof r.key==='string'&&/^[a-f0-9]{64}$/.test(r.key)&&Number.isFinite(r.at)
          &&typeof r.orderID==='string'&&typeof r.platform==='string'&&typeof r.state==='string'))throw new Error('Invalid records');
        this.data=loaded;this.data.records=this.data.records.map(r=>r.state==='发送中'?{...r,state:'发送待确认'}:r);
      }
      if(this.data.settings.selectedPlatformIDs===undefined) {
        this.data.settings.selectedPlatformIDs=[...new Set(this.sources().map(s=>s.id))].sort();
      }
      this.data.version=2;
      this.prune();
    } catch {this.fail('报警存储无法读取或保存，已停止发送；请保留记录并检查本地文件');}
  }
  fail(message='报警记录无法持久保存，已停止发送') {this.blocked=true;this.queue=[];this.message=message;}
  commit(data) {this.save(data);this.data=data;}
  prune() {
    const now=this.now();
    if(now<this.data.lastClock-60000)throw new Error('系统时间回退');
    this.commit({...this.data,lastClock:Math.max(now,this.data.lastClock),records:this.data.records.filter(r=>now-r.at<ALERT_TTL)});
    this.maintenance=now;
  }
  configure(input) {
    if(this.blocked)throw new Error(this.message);
    const previous=this.data.settings;
    const settings={enabled:input.enabled,minutes:input.minutes,lookbackDays:input.lookbackDays,
      chatID:String(input.chatID||'').trim(),token:typeof input.token==='string'&&input.token.trim()?input.token.trim():previous.token,
      selectedPlatformIDs:input.selectedPlatformIDs===undefined?previous.selectedPlatformIDs:input.selectedPlatformIDs};
    validateAlerts(settings);this.commit({...this.data,settings});
    this.generation++;this.queue=[];this.due.clear();this.message=settings.enabled?'报警已开启，等待只读查询':'报警已关闭';
    return this.snapshot();
  }
  snapshot() {
    const {token,...settings}=this.data.settings;
    return {settings:{...settings,hasToken:!!token},blocked:this.blocked,message:this.message,
      records:this.data.records.map(({platform,orderID,at,state})=>({platform,orderID,at,state})).sort((a,b)=>b.at-a.at),
      platforms:this.sources().map(s=>({id:s.id,name:s.name,selected:this.isSelected(s.id),
        message:(this.statuses.get(s.id)||'未查询')+(this.isSelected(s.id)?'':' · 不发送 TG')}))};
  }
  isSelected(id) {return this.data.settings.selectedPlatformIDs?.includes(id)===true;}
  selectPlatform(id,selected) {
    if(typeof selected!=='boolean'||!this.sources().some(s=>s.id===id))throw new Error('平台已移除或选择无效');
    const ids=new Set(this.data.settings.selectedPlatformIDs);
    if(selected)ids.add(id);else ids.delete(id);
    try{return this.configure({...this.data.settings,selectedPlatformIDs:[...ids].sort()});}
    catch{this.fail();throw new Error(this.message);}
  }
  current(source) {
    return this.sources().some(s=>s.id===source.id&&sourceScope(s)===sourceScope(source)&&s.wc===source.wc&&s.ready);
  }
  tick() {
    if(this.stopped||this.blocked)return;
    if(this.now()-this.maintenance>=60000)try{this.prune();}catch{this.fail();return;}
    if(!this.data.settings.enabled)return;
    const sources=this.sources(),ids=new Set(sources.map(s=>s.id));
    for(const id of this.due.keys())if(!ids.has(id)){this.due.delete(id);this.statuses.delete(id);}
    for(const source of sources)if(this.active.size<2&&!this.active.has(source.id)&&!this.queue.some(c=>c.source.id===source.id)
      &&(this.due.get(source.id)||0)<=this.now())void this.scan(source);
    if(!this.sending&&this.nextSend<=this.now())void this.drain();
  }
  args(source) {
    return {expectedUsername:source.account||'',allowNPG:source.allowNPG!==false,requestID:crypto.randomUUID(),
      startDate:alertDay(this.now()-(this.data.settings.lookbackDays-1)*ALERT_TTL),endDate:alertDay(this.now())};
  }
  eligible(orders,scope) {
    const keys=new Set(this.data.records.map(r=>r.key)),now=this.now();
    return orders.filter(r=>alertEligible(r,now,this.data.settings.minutes)&&!keys.has(alertKey(scope,r.id,now)));
  }
  async scan(source) {
    this.due.set(source.id,this.now()+60000);
    if(!source.ready){this.statuses.set(source.id,'页面未就绪');return;}
    this.active.add(source.id);this.statuses.set(source.id,'查询中');const generation=this.generation;
    try {
      const result=await this.execute(source,'alerts',this.args(source));
      if(this.stopped||generation!==this.generation||!this.current(source))return;
      if(result?.kind!=='ok'||!Array.isArray(result.orders)||!result.contextID||!['NPG','TC'].includes(result.family)) {
        this.statuses.set(source.id,'未完整获取，本轮不报警');return;
      }
      const scope=JSON.stringify([new URL(source.url).origin,result.family,result.country||'',result.merchant||'']);
      const orders=this.eligible(result.orders,scope);
      this.statuses.set(source.id,`已查 ${result.orders.length} 条 · 待提醒 ${this.isSelected(source.id)?orders.length:0} 条`);
      if(this.isSelected(source.id)&&orders.length)this.queue.push({source,scope,orders,contextID:result.contextID});
    } catch {this.statuses.set(source.id,'查询失败，本轮不报警');}
    finally {this.active.delete(source.id);this.due.set(source.id,this.now()+60000);}
  }
  async drain() {
    if(this.stopped||this.blocked||!this.data.settings.enabled||this.sending||!this.queue.length)return;
    const candidate=this.queue.shift(),generation=this.generation;
    if(!this.isSelected(candidate.source.id)||!this.current(candidate.source))return;
    this.sending=true;
    try {
      let result;
      try {result=await this.execute(candidate.source,'alertValidate',{...this.args(candidate.source),contextID:candidate.contextID});}
      catch {return;}
      if(this.stopped||this.blocked||generation!==this.generation||!this.isSelected(candidate.source.id)||!this.current(candidate.source)||result?.kind!=='ok')return;
      const rows=this.eligible(candidate.orders,candidate.scope).slice(0,10);
      if(!rows.length)return;
      const now=this.now();this.prune();
      const unique=new Map(rows.map(r=>[alertKey(candidate.scope,r.id,now),r]));
      const records=[...unique].map(([key,r])=>({key,platform:candidate.source.name,orderID:r.id,at:now,state:'发送中'}));
      // Persist before dispatch. Uncertain results and crashes consume today's slot.
      this.commit({...this.data,records:[...this.data.records,...records]});
      const ids=new Set(records.map(r=>r.orderID)),keys=new Set(records.map(r=>r.key));
      const remaining=candidate.orders.filter(r=>!ids.has(r.id));
      if(remaining.length)this.queue.push({...candidate,orders:remaining});
      const text=`提现挂单报警\n${clean(candidate.source.name)} · 超过 ${this.data.settings.minutes} 分钟\n`
        +[...unique.values()].map(r=>`订单 ${clean(r.id)} | ${Math.floor((now-r.createdAt)/60000)} 分钟 | ${r.status}\n创建 ${display(r.createdAt)}`).join('\n')
        +`\n查询时间（北京时间）：${display(now)}`;
      let delivery;
      try{delivery=await this.send({...this.data.settings},text);}catch{delivery={state:'发送待确认'};}
      const state=['已发送','发送失败（当天不重发）'].includes(delivery?.state)?delivery.state:'发送待确认';
      this.commit({...this.data,records:this.data.records.map(r=>keys.has(r.key)?{...r,state,messageID:delivery?.messageID||null}:r)});
      this.message=this.data.settings.enabled?'最近发送：'+state:'报警已关闭';
      this.nextSend=this.now()+3200;
    } catch {this.fail();} finally {this.sending=false;}
  }
  stop() {
    this.stopped=true;this.generation++;this.queue=[];
    for(const source of this.sources())if(this.active.has(source.id))void this.execute(source,'cancelAlerts').catch(()=>{});
  }
}
