/**
 * 离线变更队列
 * 网络不可用时暂存本地变更，恢复连接后批量推送
 */

import type { Todo, TodoList } from '../types/todo.js';

export interface PendingChange {
  id: string;
  todo?: Todo;
  list?: TodoList;
  deletedTodoId?: string;
  deletedListId?: string;
  enqueuedAt: number;
}

const QUEUE_KEY = 'woo-todo:pending-changes';

export class OfflineQueue {
  private changes: PendingChange[] = [];
  private listeners = new Set<() => void>();

  constructor() {
    this.load();
  }

  private load(): void {
    if (typeof localStorage === 'undefined') return;
    try {
      const raw = localStorage.getItem(QUEUE_KEY);
      if (raw) this.changes = JSON.parse(raw) as PendingChange[];
    } catch {
      this.changes = [];
    }
  }

  private persist(): void {
    if (typeof localStorage === 'undefined') return;
    try {
      localStorage.setItem(QUEUE_KEY, JSON.stringify(this.changes));
    } catch {
      // 存储满或不可用 - 静默失败
    }
  }

  private emit(): void {
    for (const fn of this.listeners) fn();
  }

  enqueue(change: Omit<PendingChange, 'id' | 'enqueuedAt'>): void {
    this.changes.push({
      ...change,
      id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
      enqueuedAt: Date.now(),
    });
    this.persist();
    this.emit();
  }

  /** 去重合并：同一 todo/list 的最新变更覆盖旧的 */
  drain(): PendingChange[] {
    const todoMap = new Map<string, PendingChange>();
    const listMap = new Map<string, PendingChange>();
    const deletedTodos = new Set<string>();
    const deletedLists = new Set<string>();
    const order: string[] = [];

    for (const c of this.changes) {
      if (c.todo) {
        todoMap.set(c.todo.id, c);
        order.push(c.id);
      } else if (c.list) {
        listMap.set(c.list.id, c);
        order.push(c.id);
      } else if (c.deletedTodoId) {
        deletedTodos.add(c.deletedTodoId);
        todoMap.delete(c.deletedTodoId);
        order.push(c.id);
      } else if (c.deletedListId) {
        deletedLists.add(c.deletedListId);
        listMap.delete(c.deletedListId);
        order.push(c.id);
      }
    }

    const result: PendingChange[] = [
      ...todoMap.values(),
      ...listMap.values(),
      ...Array.from(deletedTodos).map((id) => ({ id: `del-todo-${id}`, deletedTodoId: id, enqueuedAt: Date.now() })),
      ...Array.from(deletedLists).map((id) => ({ id: `del-list-${id}`, deletedListId: id, enqueuedAt: Date.now() })),
    ];

    return result;
  }

  clear(): void {
    this.changes = [];
    this.persist();
    this.emit();
  }

  size(): number {
    return this.changes.length;
  }

  subscribe(fn: () => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }
}

export const offlineQueue = new OfflineQueue();
