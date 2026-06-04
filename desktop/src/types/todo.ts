export interface Todo {
  id: string
  title: string
  completed: boolean
  createdAt: number
  updatedAt: number
  isDeleted: boolean
}

export interface AppSettings {
  alwaysOnTop: boolean
  transparentMode: boolean
}

export interface ElectronAPI {
  toggleAlwaysOnTop: () => Promise<boolean>
  toggleTransparentMode: () => Promise<boolean>
  getSettings: () => Promise<AppSettings>
  onTransparentModeChanged: (callback: (enabled: boolean) => void) => void
  onFocusAddInput: (callback: () => void) => void
}

declare global {
  interface Window {
    electronAPI: ElectronAPI
  }
}
