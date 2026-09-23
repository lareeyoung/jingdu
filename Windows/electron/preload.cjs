const { contextBridge, ipcRenderer } = require('electron');
const channels = new Set(['load', 'save', 'importVideos', 'importBackup', 'exportBackup', 'playback', 'thumbnails', 'waveform', 'detectCuts', 'relink', 'settings', 'saveSettings', 'chooseModel', 'models', 'subtitles', 'script', 'exportSRT', 'cancel', 'openGuide']);
contextBridge.exposeInMainWorld('jingdu', Object.freeze({
  invoke(channel, payload) {
    if (!channels.has(channel)) return Promise.reject(new Error('不支持的操作'));
    return ipcRenderer.invoke('jingdu:' + channel, payload);
  },
  onProgress(callback) {
    const listener = (_event, data) => callback(data);
    ipcRenderer.on('jingdu:progress', listener);
    return () => ipcRenderer.removeListener('jingdu:progress', listener);
  },
  onBeforeClose(callback) {
    ipcRenderer.on('jingdu:before-close', async () => {
      try { await callback(); ipcRenderer.send('jingdu:close-ready'); }
      catch { ipcRenderer.send('jingdu:close-failed'); }
    });
  }
}));
