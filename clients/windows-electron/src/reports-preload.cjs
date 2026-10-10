const {contextBridge, ipcRenderer} = require('electron');
contextBridge.exposeInMainWorld('reportApi', {
  get: () => ipcRenderer.invoke('reports:get'),
  configure: input => ipcRenderer.invoke('reports:configure', input),
  fetch: () => ipcRenderer.invoke('reports:fetch'),
  cancel: () => ipcRenderer.invoke('reports:cancel'),
  navigate: target => ipcRenderer.invoke('reports:navigate', target),
  onChange: callback => {
    const handler=(_event,data)=>callback(data);
    ipcRenderer.on('reports:changed',handler);
    return ()=>ipcRenderer.removeListener('reports:changed',handler);
  }
});
