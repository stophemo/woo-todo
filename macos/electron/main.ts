import { app, BrowserWindow, globalShortcut, Tray, Menu, ipcMain, nativeTheme } from 'electron'
import path from 'path'
import Store from 'electron-store'

const store = new Store({
  defaults: {
    alwaysOnTop: true,
    transparentMode: true,
    windowPosition: { x: 100, y: 100 },
  },
})

let mainWindow: BrowserWindow | null = null
let tray: Tray | null = null

function createWindow() {
  const { x, y } = store.get('windowPosition') as { x: number; y: number }

  mainWindow = new BrowserWindow({
    width: 320,
    height: 500,
    x,
    y,
    transparent: true,
    frame: false,
    alwaysOnTop: store.get('alwaysOnTop') as boolean,
    resizable: false,
    skipTaskbar: true,
    type: 'panel',
    vibrancy: 'under-window',
    visualEffectState: 'active',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      nodeIntegration: false,
      contextIsolation: true,
    },
  })

  // 应用透明穿透模式
  applyTransparentMode(store.get('transparentMode') as boolean)

  // 保存窗口位置
  mainWindow.on('moved', () => {
    if (mainWindow) {
      const [x, y] = mainWindow.getPosition()
      store.set('windowPosition', { x, y })
    }
  })

  // 开发模式加载 Vite dev server
  if (process.env.VITE_DEV_SERVER_URL) {
    mainWindow.loadURL(process.env.VITE_DEV_SERVER_URL)
  } else {
    mainWindow.loadFile(path.join(__dirname, '../dist/index.html'))
  }
}

function applyTransparentMode(enabled: boolean) {
  if (!mainWindow) return
  // 透明穿透：忽略所有鼠标事件，事件穿透到底层应用
  mainWindow.setIgnoreMouseEvents(enabled, { forward: true })
  // 通知渲染进程切换 UI
  mainWindow.webContents.send('transparent-mode-changed', enabled)
}

function toggleAlwaysOnTop() {
  const current = !store.get('alwaysOnTop')
  store.set('alwaysOnTop', current)
  mainWindow?.setAlwaysOnTop(current)
}

function toggleTransparentMode() {
  const current = !store.get('transparentMode')
  store.set('transparentMode', current)
  applyTransparentMode(current)
}

function registerShortcuts() {
  globalShortcut.register('Cmd+Shift+T', toggleAlwaysOnTop)
  globalShortcut.register('Cmd+Shift+G', toggleTransparentMode)
  globalShortcut.register('Cmd+Shift+N', () => {
    // 快速新增：先切到交互模式
    if (store.get('transparentMode')) {
      store.set('transparentMode', false)
      applyTransparentMode(false)
    }
    mainWindow?.webContents.send('focus-add-input')
  })
}

function createTray() {
  // 使用简单的 emoji 或文字作为托盘图标
  tray = new Tray(path.join(__dirname, '../assets/tray-icon.png'))
  const contextMenu = Menu.buildFromTemplate([
    {
      label: store.get('transparentMode') ? '取消透明化' : '透明化',
      click: toggleTransparentMode,
    },
    {
      label: store.get('alwaysOnTop') ? '取消置顶' : '置于顶层',
      click: toggleAlwaysOnTop,
    },
    { type: 'separator' },
    { label: '退出无我待办', click: () => app.quit() },
  ])
  tray.setToolTip('无我待办')
  tray.setContextMenu(contextMenu)
}

// IPC 处理
ipcMain.handle('toggle-always-on-top', () => {
  toggleAlwaysOnTop()
  return store.get('alwaysOnTop')
})

ipcMain.handle('toggle-transparent-mode', () => {
  toggleTransparentMode()
  return store.get('transparentMode')
})

ipcMain.handle('get-settings', () => {
  return {
    alwaysOnTop: store.get('alwaysOnTop'),
    transparentMode: store.get('transparentMode'),
  }
})

app.whenReady().then(() => {
  createWindow()
  registerShortcuts()
  createTray()

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit()
})

app.on('will-quit', () => {
  globalShortcut.unregisterAll()
})
