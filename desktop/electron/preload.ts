import { contextBridge, ipcRenderer } from 'electron'

contextBridge.exposeInMainWorld('electronAPI', {
  toggleAlwaysOnTop: () => ipcRenderer.invoke('toggle-always-on-top'),
  toggleTransparentMode: () => ipcRenderer.invoke('toggle-transparent-mode'),
  getSettings: () => ipcRenderer.invoke('get-settings'),
  onTransparentModeChanged: (callback: (enabled: boolean) => void) => {
    ipcRenderer.on('transparent-mode-changed', (_event, enabled) => callback(enabled))
  },
  onFocusAddInput: (callback: () => void) => {
    ipcRenderer.on('focus-add-input', () => callback())
  },
})
