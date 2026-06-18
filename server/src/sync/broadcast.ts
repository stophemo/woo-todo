import type { WebSocket } from 'ws';
import type { Todo, TodoList } from '@woo-todo/core';
import type { BroadcastUpdate } from '@woo-todo/core';

export class BroadcastManager {
  private clients = new Set<WebSocket>();

  add(ws: WebSocket): void {
    this.clients.add(ws);
  }

  remove(ws: WebSocket): void {
    this.clients.delete(ws);
  }

  size(): number {
    return this.clients.size;
  }

  broadcast(originDeviceId: string, todos: Todo[], lists: TodoList[], deletedTodoIds: string[], deletedListIds: string[], serverTime: number): void {
    const msg: BroadcastUpdate = {
      type: 'broadcast',
      originDeviceId,
      todos,
      lists,
      deletedTodoIds,
      deletedListIds,
      serverTime,
    };
    const data = JSON.stringify(msg);
    for (const ws of this.clients) {
      if (ws.readyState === ws.OPEN) ws.send(data);
    }
  }
}

export const broadcast = new BroadcastManager();
