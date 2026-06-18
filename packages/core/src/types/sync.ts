import type { Todo, TodoList } from './todo.js';

export type SyncStatus = 'idle' | 'connecting' | 'connected' | 'syncing' | 'offline' | 'error';

export interface SyncMessage {
  type: 'sync';
  deviceId: string;
  todos: Todo[];
  lists: TodoList[];
  deletedTodoIds: string[];
  deletedListIds: string[];
  since: number; // 客户端最后同步时间
}

export interface SyncAck {
  type: 'ack';
  serverTime: number;
  accepted: number;
  rejected: number;
}

export interface SyncPull {
  type: 'pull';
  since: number;
}

export interface SyncPullResponse {
  type: 'pull-response';
  todos: Todo[];
  lists: TodoList[];
  deletedTodoIds: string[];
  deletedListIds: string[];
  serverTime: number;
}

export interface BroadcastUpdate {
  type: 'broadcast';
  originDeviceId: string;
  todos: Todo[];
  lists: TodoList[];
  deletedTodoIds: string[];
  deletedListIds: string[];
  serverTime: number;
}

export type ServerMessage = SyncAck | SyncPullResponse | BroadcastUpdate;
export type ClientMessage = SyncMessage | SyncPull;

export interface NetworkState {
  online: boolean;
  serverReachable: boolean;
  lastSyncAt: number | null;
  pendingChanges: number;
}
