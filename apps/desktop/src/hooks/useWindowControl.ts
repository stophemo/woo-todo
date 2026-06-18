/**
 * 桌面端 window API 桥接
 * 包装 Tauri invoke + event，向上层暴露简单 Promise 接口
 */

import { invoke } from '@tauri-apps/api/core';
import { listen, type UnlistenFn } from '@tauri-apps/api/event';

export interface WindowState {
  alwaysOnTop: boolean;
  penetrate: boolean;
}

export const windowApi = {
  async toggleAlwaysOnTop(): Promise<boolean> {
    return invoke<boolean>('toggle_always_on_top');
  },
  async togglePenetrate(): Promise<boolean> {
    return invoke<boolean>('toggle_penetrate');
  },
  async getState(): Promise<WindowState> {
    return invoke<WindowState>('get_window_state');
  },
  async moveWindow(dx: number, dy: number): Promise<void> {
    return invoke('move_window', { dx, dy });
  },
  async onStateChange(handler: (state: WindowState) => void): Promise<UnlistenFn> {
    return listen<WindowState>('window-state', (e) => handler(e.payload));
  },
};
