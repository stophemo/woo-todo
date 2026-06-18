/**
 * 网络状态监测
 * 浏览器环境用 navigator.onLine + online/offline 事件
 * RN 环境可通过 NetInfo 注入
 */

import type { NetworkState } from '../types/sync.js';

export type NetworkListener = (online: boolean) => void;

export class NetworkMonitor {
  private listeners = new Set<NetworkListener>();
  private state: NetworkState = {
    online: typeof navigator !== 'undefined' ? navigator.onLine : true,
    serverReachable: true,
    lastSyncAt: null,
    pendingChanges: 0,
  };
  private pingUrl: string | null = null;
  private pingTimer: ReturnType<typeof setInterval> | null = null;

  constructor() {
    if (typeof window !== 'undefined') {
      window.addEventListener('online', this.handleOnline);
      window.addEventListener('offline', this.handleOffline);
    }
  }

  destroy(): void {
    if (typeof window !== 'undefined') {
      window.removeEventListener('online', this.handleOnline);
      window.removeEventListener('offline', this.handleOffline);
    }
    if (this.pingTimer) clearInterval(this.pingTimer);
    this.listeners.clear();
  }

  private handleOnline = (): void => {
    this.update({ online: true });
  };

  private handleOffline = (): void => {
    this.update({ online: false, serverReachable: false });
  };

  private update(patch: Partial<NetworkState>): void {
    this.state = { ...this.state, ...patch };
    if (patch.online !== undefined) {
      for (const fn of this.listeners) fn(patch.online);
    }
  }

  getState(): NetworkState {
    return { ...this.state };
  }

  setPending(n: number): void {
    this.update({ pendingChanges: n });
  }

  markSynced(): void {
    this.update({ lastSyncAt: Date.now(), serverReachable: true });
  }

  /** 启动定时 ping 服务端健康检查 */
  startHealthCheck(url: string, intervalMs = 30000): void {
    this.pingUrl = url;
    if (this.pingTimer) clearInterval(this.pingTimer);
    const tick = async () => {
      try {
        const res = await fetch(url, { method: 'GET' });
        this.update({ serverReachable: res.ok });
      } catch {
        this.update({ serverReachable: false });
      }
    };
    void tick();
    this.pingTimer = setInterval(tick, intervalMs);
  }

  subscribe(fn: NetworkListener): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }
}

export const networkMonitor = new NetworkMonitor();
