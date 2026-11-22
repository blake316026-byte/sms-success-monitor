const {ipcRenderer}=require('electron');
// Isolated-world listener: page scripts cannot forge a trusted human edit.
for(const type of ['pointerdown','keydown','input','paste','submit'])
  document.addEventListener(type,event=>{if(event.isTrusted)ipcRenderer.send('platform:activity');},true);
