const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('smsApi', {
  getSnapshot: () => ipcRenderer.invoke('snapshot:get'),
  selectPage: (id) => ipcRenderer.invoke('page:select', id),
  navigate: (url) => ipcRenderer.invoke('page:navigate', url),
  goBack: () => ipcRenderer.invoke('page:back'),
  goForward: () => ipcRenderer.invoke('page:forward'),
  reload: () => ipcRenderer.invoke('page:reload'),
  addPage: (page) => ipcRenderer.invoke('page:add', page),
  closePage: (id) => ipcRenderer.invoke('page:close', id),
  scan: (id) => ipcRenderer.invoke('monitor:scan', id || null),
  setSampleLimit: (value) => ipcRenderer.invoke('settings:set-sample-limit', value),
  changeWorkbenchZoom: (direction) => ipcRenderer.invoke('workbench:zoom', direction),
  getCredentials: (id) => ipcRenderer.invoke('credentials:get', id),
  saveCredentials: (id, profile) => ipcRenderer.invoke('credentials:save', id, profile),
  removeCredentials: (id) => ipcRenderer.invoke('credentials:remove', id),
  showWorkbench: (id) => ipcRenderer.invoke('window:workbench', id || null),
  showDetail: () => ipcRenderer.invoke('window:detail'),
  quit: () => ipcRenderer.invoke('app:quit'),
  showWidgetMenu: () => ipcRenderer.invoke('widget:menu'),
  onSnapshot: (callback) => {
    const handler = (_event, snapshot) => callback(snapshot);
    ipcRenderer.on('snapshot:changed', handler);
    return () => ipcRenderer.removeListener('snapshot:changed', handler);
  }
});
