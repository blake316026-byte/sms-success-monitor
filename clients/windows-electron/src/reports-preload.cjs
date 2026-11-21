const {contextBridge, ipcRenderer} = require('electron');
contextBridge.exposeInMainWorld('reportApi', {
  get: () => ipcRenderer.invoke('reports:get'),
  alerts: () => ipcRenderer.invoke('reports:alerts'),
  saveAlerts: input => ipcRenderer.invoke('reports:saveAlerts',input),
  selectAlertPlatform: (id,selected) => ipcRenderer.invoke('reports:selectAlertPlatform',{id,selected}),
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
