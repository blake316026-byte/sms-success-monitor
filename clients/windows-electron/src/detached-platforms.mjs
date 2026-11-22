import {BrowserWindow,ipcMain,Menu,screen} from 'electron';
import crypto from 'node:crypto';
import path from 'node:path';
import {withDeadline} from './background-authentication.mjs';

export class DetachedPlatforms {
  constructor({pages,mainWindow,memory,busy,removeMain,returned,changed,metadata,scripts,directory}){
    Object.assign(this,{pages,mainWindow,memory,busy,removeMain,returned,changed,metadata,scripts,directory});
    this.windows=new Map();this.moving=new Set();
  }
  active(id){return this.windows.has(id)||this.moving.has(id);}
  info(id){const w=this.windows.get(id);return w?{detached:true,dragToken:w.token}:{};}
  focus(id){const entry=this.windows.get(id);if(!entry)return false;entry.window.show();entry.window.focus();return true;}
  async presentation(page,key,token){return withDeadline(()=>page.view.webContents.executeJavaScript(`(async(token)=>{${this.scripts[key]}\n})(${JSON.stringify(token)})`),4000);}
  async move(id,action){
    const page=this.pages.get(id);if(!page||this.moving.has(id))return false;
    if(this.memory.transitioning(id)||this.memory.inUse(id)||this.busy(id)||page.view.webContents.isLoadingMainFrame())return false;
    if(!await this.memory.restore(id))return false;
    const wc=page.view.webContents,url=wc.getURL(),token=crypto.randomUUID();
    this.moving.add(id);
    try{
      await this.presentation(page,'moveCapture',token);
      if(this.pages.get(id)!==page||wc.isDestroyed()||wc.getURL()!==url||wc.isLoadingMainFrame()||this.memory.inUse(id)||this.busy(id))return false;
      await action(page);
      await this.presentation(page,'moveRestore',token).catch(()=>{});
      return true;
    }catch{return false;}
    finally{this.moving.delete(id);if(!wc.isDestroyed())void this.presentation(page,'moveDiscard',token).catch(()=>{});this.changed();}
  }
  async detach(id,point){
    if(this.focus(id))return true;
    if(this.windows.size>=3)return false;
    return this.move(id,async page=>{
      const area=screen.getDisplayNearestPoint(point||screen.getCursorScreenPoint()).workArea;
      const width=Math.min(1100,area.width),height=Math.min(760,area.height);
      const window=new BrowserWindow({show:false,width,height,minWidth:620,minHeight:450,
        x:Math.max(area.x,Math.min(point?.x??area.x+30,area.x+area.width-width)),
        y:Math.max(area.y,Math.min(point?.y??area.y+30,area.y+area.height-height)),
        title:page.name,backgroundColor:'#ffffff',webPreferences:{preload:path.join(this.directory,'detached-preload.cjs'),contextIsolation:true,nodeIntegration:false,sandbox:true}});
      const entry={window,token:crypto.randomUUID(),page,returning:false};
      window.webContents.setWindowOpenHandler(()=>({action:'deny'}));window.webContents.on('will-navigate',e=>e.preventDefault());
      try{await window.loadFile(path.join(this.directory,'../build/detached.html'));}catch(error){window.destroy();throw error;}
      // Recheck after loading the local header; never move an active transaction.
      if(this.memory.inUse(id)||this.busy(id)||page.view.webContents.isDestroyed()||page.view.webContents.isLoadingMainFrame()){window.destroy();throw Error('Platform busy');}
      this.windows.set(id,entry);this.removeMain(id);
      window.contentView.addChildView(page.view);
      const layout=()=>{if(window.isDestroyed())return;const b=window.getContentBounds();page.view.setBounds({x:0,y:48,width:b.width,height:Math.max(1,b.height-48)});};
      window.on('resize',layout);layout();
      window.on('close',event=>{event.preventDefault();if(!entry.returning)void this.returnPage(id);});
      window.webContents.send('detached:state',this.snapshot(id));window.show();window.focus();
    });
  }
  snapshot(id){const e=this.windows.get(id),p=this.pages.get(id);return e&&p?{id,name:p.name,...this.metadata(id),token:e.token,
    back:p.view.webContents.navigationHistory.canGoBack(),forward:p.view.webContents.navigationHistory.canGoForward()}:null;}
  notify(){for(const [id,e]of this.windows)if(!e.window.isDestroyed())e.window.webContents.send('detached:state',this.snapshot(id));}
  async returnPage(id){
    const e=this.windows.get(id);if(!e||e.returning)return false;e.returning=true;
    const moved=await this.move(id,async page=>{
      e.window.contentView.removeChildView(page.view);this.windows.delete(id);
      this.returned(id);e.window.hide();e.window.removeAllListeners('close');
    });
    if(!moved)e.returning=false;
    else setTimeout(()=>{if(!e.window.isDestroyed())e.window.destroy();},100);
    return moved;
  }
  install(){
    this.installed=true;
    const trustedMain=e=>e.sender===this.mainWindow()?.webContents&&e.senderFrame===e.sender.mainFrame;
    const owner=e=>[...this.windows].find(([,v])=>v.window.webContents===e.sender&&e.senderFrame===e.sender.mainFrame)?.[0];
    ipcMain.handle('platform:detach',async(e,id,point)=>{
      if(!trustedMain(e)||typeof id!=='string')return false;
      return this.detach(id,point&&Number.isFinite(point.x)&&Number.isFinite(point.y)?{x:Math.round(point.x),y:Math.round(point.y)}:undefined);
    });
    ipcMain.handle('platform:return',async(e,id,token)=>trustedMain(e)&&this.windows.get(id)?.token===token?this.returnPage(id):false);
    ipcMain.handle('platform:menu',(e,id)=>{
      if(!trustedMain(e)||!this.pages.has(id))return false;
      Menu.buildFromTemplate([{label:this.windows.has(id)?'放回主窗口':'在独立窗口打开',click:()=>void(this.windows.has(id)?this.returnPage(id):this.detach(id))}]).popup({window:this.mainWindow()});return true;
    });
    ipcMain.handle('detached:get',e=>{const id=owner(e);return id?this.snapshot(id):null;});
    ipcMain.handle('detached:command',async(e,command)=>{
      const id=owner(e),page=this.pages.get(id);if(!id||!page)return false;
      if(command==='return')return this.returnPage(id);
      if(this.busy(id)||this.memory.inUse(id)||this.moving.has(id))return false;
      const wc=page.view.webContents,history=wc.navigationHistory;
      if(command==='back'&&history.canGoBack())history.goBack();
      else if(command==='forward'&&history.canGoForward())history.goForward();
      else if(command==='reload')wc.reloadIgnoringCache();else return false;
      return true;
    });
  }
  dispose(){
    for(const e of this.windows.values()){e.window.contentView.removeChildView(e.page.view);e.window.removeAllListeners('close');e.window.destroy();}this.windows.clear();
    if(this.installed)for(const key of ['platform:detach','platform:return','platform:menu','detached:get','detached:command'])ipcMain.removeHandler(key);
    this.installed=false;
  }
}
