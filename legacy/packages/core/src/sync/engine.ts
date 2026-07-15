/**
 * 同步引擎 - 客户端
 * 职责：
 * 1. 建立 WebSocket 长连接，接收服务端广播
 * 2. 监听 store 变更，将本地操作推送到服务端
 * 3. 离线时暂存到 offline-queue，恢复后批量推送
 * 4. 启动时调用 REST 拉取全量快照（增量）
 */

import { useTodoStore, type TodoStore } from '../store/todoStore.js';
import type { ClientMessage, ServerMessage } from '../types/sync.js';
import { offlineQueue } from './offline-queue.js';
import { networkMonitor } from './network-monitor.js';

export interface SyncEngineOptions {
  serverUrl: string; // e.g. http://localhost:3001
  deviceId: string;
  reconnectIntervalMs?: number;
  pingIntervalMs?: number;
}

export class SyncEngine {
  private ws: WebSocket | null = null;
  private opts: Required<SyncEngineOptions>;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private pingTimer: ReturnType<typeof setInterval> | null = null;
  private lastSyncAt = 0;
  private connected = false;
  private pendingFlush = false;
  private unsubscribeNetwork: (() => void) | null = null;

  constructor(opts: SyncEngineOptions) {
    this.opts = {
      reconnectIntervalMs: 3000,
      pingIntervalMs: 25000,
      ...opts,
    };
  }

  start(): void {
    this.connect();
    this.subscribeLocalChanges();
    networkMonitor.startHealthCheck(`${this.opts.serverUrl}/health`);
  }

  stop(): void {
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    if (this.pingTimer) clearInterval(this.pingTimer);
    this.ws?.close();
    this.ws = null;
    this.connected = false;
    this.unsubscribeNetwork?.();
  }

  private connect(): void {
    if (this.ws && (this.ws.readyState === WebSocket.OPEN || this.ws.readyState === WebSocket.CONNECTING)) {
      return;
    }

    const wsUrl = this.opts.serverUrl.replace(/^http/, 'ws') + '/ws';
    const ws = new WebSocket(wsUrl);
    this.ws = ws;

    ws.onopen = () => {
      this.connected = true;
      this.lastSyncAt = Date.now();
      // 拉取增量
      this.send({ type: 'pull', since: this.lastSyncAt });
      // 推送离线队列
      this.flushQueue();
    };

    ws.onmessage = (event) => {
      try {
        const msg = JSON.parse(event.data) as ServerMessage;
        this.handleServerMessage(msg);
      } catch {
        // 忽略非法消息
      }
    };

    ws.onclose = () => {
      this.connected = false;
      this.ws = null;
      this.scheduleReconnect();
    };

    ws.onerror = () => {
      // onclose 会处理重连
    };
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimer) return;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, this.opts.reconnectIntervalMs);
  }

  private send(msg: ClientMessage): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    this.ws.send(JSON.stringify(msg));
  }

  private handleServerMessage(msg: ServerMessage): void {
    const store = useTodoStore.getState();
    if (msg.type === 'broadcast') {
      if (msg.originDeviceId === this.opts.deviceId) return; // 自己的回声
      store.applyRemoteTodos(msg.todos, msg.lists, msg.deletedTodoIds, msg.deletedListIds);
    } else if (msg.type === 'pull-response') {
      store.applyRemoteTodos(msg.todos, msg.lists, msg.deletedTodoIds, msg.deletedListIds);
      this.lastSyncAt = msg.serverTime;
      networkMonitor.markSynced();
    } else if (msg.type === 'ack') {
      this.lastSyncAt = msg.serverTime;
      networkMonitor.markSynced();
    }
  }

  private subscribeLocalChanges(): void {
    // 本地变更入队由调用方显式 enqueueAndFlush，不在此订阅
    this.unsubscribeNetwork = networkMonitor.subscribe((online) => {
      if (online && !this.connected) this.connect();
    });
  }

  /** 把本地新变更推入离线队列 + 立即尝试推送 */
  enqueueAndFlush(change: Parameters<typeof offlineQueue.enqueue>[0]): void {
    offlineQueue.enqueue(change);
    networkMonitor.setPending(offlineQueue.size());
    void this.flushQueue();
  }

  /** 把离线队列中的变更批量推送到服务端 */
  async flushQueue(): Promise<void> {
    if (this.pendingFlush) return;
    if (!this.connected) return;

    this.pendingFlush = true;
    try {
      const changes = offlineQueue.drain();
      if (changes.length === 0) return;

      const todos: import('../types/todo.js').Todo[] = [];
      const lists: import('../types/todo.js').TodoList[] = [];
      const deletedTodoIds: string[] = [];
      const deletedListIds: string[] = [];

      for (const c of changes) {
        if (c.todo) todos.push(c.todo);
        else if (c.list) lists.push(c.list);
        else if (c.deletedTodoId) deletedTodoIds.push(c.deletedTodoId);
        else if (c.deletedListId) deletedListIds.push(c.deletedListId);
      }

      this.send({
        type: 'sync',
        deviceId: this.opts.deviceId,
        todos,
        lists,
        deletedTodoIds,
        deletedListIds,
        since: this.lastSyncAt,
      });

      offlineQueue.clear();
      networkMonitor.setPending(0);
    } finally {
      this.pendingFlush = false;
    }
  }
}

export type { TodoStore };
