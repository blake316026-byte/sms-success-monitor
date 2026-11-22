import {withDeadline} from './background-authentication.mjs';

// The native lease covers queries and the entire write/readback promise. It never
// expires on a timer: an uncertain business operation must not be navigated away.
export class PlatformMemory {
  constructor({pages,active,busy,profile,family,canSuspend,scripts,changed=()=>{},now=Date.now,delay=180000}) {
    Object.assign(this,{pages,active,busy,profile,family,canSuspend,scripts,changed,now,delay});
    this.states=new Map();this.leases=new Map();
  }
  state(id){if(!this.states.has(id))this.states.set(id,{inactiveSince:this.now(),touched:false,transition:false,compacted:false,cooldown:0,lastProbe:0});return this.states.get(id);}
  inUse(id){return (this.leases.get(id)||0)>0;}
  transitioning(id){return this.state(id).transition;}
  compacted(id){return this.state(id).compacted;}
  async withLease(id,run){
    if(this.transitioning(id))throw new Error('平台页面正在恢复，请稍后重新查询；未提交操作');
    this.leases.set(id,(this.leases.get(id)||0)+1);
    try{return await run();}finally{const n=this.leases.get(id)-1;if(n)this.leases.set(id,n);else this.leases.delete(id);}
  }
  attach(page){
    const wc=page.view.webContents,s=this.state(page.id);
    wc.on('did-start-navigation',(_e,_url,inPlace,main)=>{if(main&&!inPlace&&!s.transition){s.touched=false;s.compacted=false;s.restoreURL=null;s.inactiveSince=this.now();}});
    wc.on('dom-ready',()=>{if(!wc.isDestroyed())void wc.executeJavaScript(this.scripts.memoryActivity).catch(()=>{});});
    wc.on('destroyed',()=>{this.states.delete(page.id);this.leases.delete(page.id);});
  }
  touch(id){this.state(id).touched=true;}
  recordSuccessfulRead(id){this.state(id).authenticatedRead={at:this.now(),profile:this.profile(id)};}
  invalidateRead(id){this.state(id).authenticatedRead=null;}
  hasFreshRead(id){
    const s=this.state(id),r=s.authenticatedRead,now=this.now();
    return Boolean(r&&r.profile===this.profile(id)&&r.at>s.compactedAt&&r.at<=now&&now-r.at<=120000);
  }
  script(page,key,extra={}){
    const args={expectedUsername:this.profile(page.id)?.username||'',allowNPG:true,requiredNPGPermission:'',...extra};
    return page.view.webContents.executeJavaScript(`(async(${Object.keys(args).join(',')})=>{${this.scripts[key]}\n})(...${JSON.stringify(Object.values(args))})`);
  }
  async restore(id){
    const page=this.pages.get(id),s=this.state(id);
    if(!page||!s.compacted)return !s.transition;
    if(s.transition||this.inUse(id)||this.busy(id))return false;
    s.transition=true;const url=s.restoreURL;
    try{
      await page.view.webContents.loadURL(url);
      s.compacted=false;s.restoreURL=null;s.inactiveSince=this.now();s.touched=false;
      return true;
    }catch{ s.cooldown=this.now()+300000;return false; }
    finally{s.transition=false;this.changed();}
  }
  async tick(id){
    const page=this.pages.get(id),s=this.state(id),now=this.now();
    if(!page||page.view.webContents.isDestroyed())return;
    const wc=page.view.webContents;
    if(this.active(id)){s.inactiveSince=now;if(s.compacted)await this.restore(id);return;}
    if(s.transition||this.inUse(id)||this.busy(id)||wc.isLoadingMainFrame())return;
    if(s.compacted){
      if(now-s.lastProbe<30000)return;s.lastProbe=now;
      const url=wc.getURL(),profile=this.profile(id);s.transition=true;
      let status='unavailable';
      try {status=this.family(id)==='TC'?await withDeadline(()=>this.script(page,'memoryProbe'),12000):
        now-s.compactedAt>=120000&&!this.hasFreshRead(id)?'wake':'valid';}catch{}
      finally{s.transition=false;}
      if(this.pages.get(id)!==page||this.profile(id)!==profile||wc.isDestroyed()||wc.getURL()!==url)return;
      if(status!=='valid'&&status!=='blocked'){
        s.cooldown=this.now()+(status==='expired'||status==='auth'||status==='wake'?60000:300000);
        await this.restore(id);
      }
      return;
    }
    if(s.touched||s.cooldown>now||now-s.inactiveSince<this.delay||!this.canSuspend(id))return;
    let url;try{url=new URL(wc.getURL());if(url.origin!==new URL(page.url).origin||['/','/login','/ga-auth','/unlock-ip'].includes(url.pathname))return;}catch{return;}
    const originalURL=wc.getURL(),profile=this.profile(id);s.transition=true;
    try{
      const snapshot=await withDeadline(()=>this.script(page,'memorySnapshot',{tiancheng:this.family(id)==='TC'}),12000);
      if(!snapshot||!['TC','NPG'].includes(snapshot.family)||this.pages.get(id)!==page||this.profile(id)!==profile
        ||wc.isDestroyed()||wc.getURL()!==originalURL||wc.isLoadingMainFrame()||this.active(id)||s.touched||this.inUse(id)||this.busy(id))return;
      // loadDataWithBaseURL retains this WebContents' origin and sessionStorage;
      // persistent Cookies/localStorage stay in the original per-platform partition.
      url.pathname='/.sms-monitor-memory-shell';url.search='';
      s.restoreURL=originalURL;s.compacted=true;s.compactedAt=this.now();s.lastProbe=0;
      await wc.loadURL('data:text/html;charset=utf-8,'+encodeURIComponent('<!doctype html><meta charset="utf-8"><title>SMS Workbench</title><script>window.__smsMonitorMemoryCompacted=true</script>'),{baseURLForDataURL:url.href});
      this.changed();
    }catch{s.cooldown=this.now()+300000;}
    finally{s.transition=false;}
  }
}
