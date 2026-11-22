const {contextBridge,ipcRenderer}=require('electron');
contextBridge.exposeInMainWorld('detachedApi',{
  get:()=>ipcRenderer.invoke('detached:get'),
  command:c=>ipcRenderer.invoke('detached:command',c),
  onState:callback=>ipcRenderer.on('detached:state',(_e,state)=>callback(state))
});
