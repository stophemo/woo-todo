/**
 * IndexedDB 存储适配器 - 桌面端 (Tauri WebView / 浏览器)
 * 使用 idb-keyval 模式，无外部依赖、原生 IndexedDB API
 */

import type { Todo, TodoList } from '../types/todo.js';
import type { StorageAdapter } from './interface.js';

const DB_NAME = 'woo-todo';
const DB_VERSION = 1;
const TODO_STORE = 'todos';
const LIST_STORE = 'lists';

function openDB(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(TODO_STORE)) {
        const s = db.createObjectStore(TODO_STORE, { keyPath: 'id' });
        s.createIndex('listId', 'listId', { unique: false });
        s.createIndex('updatedAt', 'updatedAt', { unique: false });
      }
      if (!db.objectStoreNames.contains(LIST_STORE)) {
        db.createObjectStore(LIST_STORE, { keyPath: 'id' });
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

function tx<T>(db: IDBDatabase, stores: string[], mode: IDBTransactionMode, fn: (t: IDBTransaction) => Promise<T> | T): Promise<T> {
  return new Promise((resolve, reject) => {
    const t = db.transaction(stores, mode);
    let result: T;
    t.oncomplete = () => resolve(result);
    t.onerror = () => reject(t.error);
    t.onabort = () => reject(t.error);
    Promise.resolve(fn(t)).then((r) => { result = r; }).catch(reject);
  });
}

export class IndexedDBStorage implements StorageAdapter {
  private dbPromise: Promise<IDBDatabase> | null = null;

  private getDB(): Promise<IDBDatabase> {
    return (this.dbPromise ??= openDB());
  }

  async init(): Promise<void> {
    await this.getDB();
  }

  async getAllTodos(): Promise<Todo[]> {
    const db = await this.getDB();
    return tx(db, [TODO_STORE], 'readonly', (t) => {
      return new Promise<Todo[]>((resolve, reject) => {
        const req = t.objectStore(TODO_STORE).getAll();
        req.onsuccess = () => resolve((req.result as Todo[]) ?? []);
        req.onerror = () => reject(req.error);
      });
    });
  }

  async getTodo(id: string): Promise<Todo | null> {
    const db = await this.getDB();
    return tx(db, [TODO_STORE], 'readonly', (t) => {
      return new Promise<Todo | null>((resolve, reject) => {
        const req = t.objectStore(TODO_STORE).get(id);
        req.onsuccess = () => resolve((req.result as Todo) ?? null);
        req.onerror = () => reject(req.error);
      });
    });
  }

  async upsertTodos(todos: Todo[]): Promise<void> {
    if (todos.length === 0) return;
    const db = await this.getDB();
    await tx(db, [TODO_STORE], 'readwrite', (t) => {
      const s = t.objectStore(TODO_STORE);
      for (const todo of todos) s.put(todo);
    });
  }

  async softDeleteTodo(id: string, deletedAt: number): Promise<void> {
    const existing = await this.getTodo(id);
    if (!existing) return;
    await this.upsertTodos([{ ...existing, deletedAt, updatedAt: deletedAt }]);
  }

  async hardDeleteTodo(id: string): Promise<void> {
    const db = await this.getDB();
    await tx(db, [TODO_STORE], 'readwrite', (t) => {
      t.objectStore(TODO_STORE).delete(id);
    });
  }

  async getAllLists(): Promise<TodoList[]> {
    const db = await this.getDB();
    return tx(db, [LIST_STORE], 'readonly', (t) => {
      return new Promise<TodoList[]>((resolve, reject) => {
        const req = t.objectStore(LIST_STORE).getAll();
        req.onsuccess = () => resolve((req.result as TodoList[]) ?? []);
        req.onerror = () => reject(req.error);
      });
    });
  }

  async upsertLists(lists: TodoList[]): Promise<void> {
    if (lists.length === 0) return;
    const db = await this.getDB();
    await tx(db, [LIST_STORE], 'readwrite', (t) => {
      const s = t.objectStore(LIST_STORE);
      for (const list of lists) s.put(list);
    });
  }

  async softDeleteList(id: string, deletedAt: number): Promise<void> {
    const db = await this.getDB();
    await tx(db, [LIST_STORE], 'readwrite', (t) => {
      const req = t.objectStore(LIST_STORE).get(id);
      req.onsuccess = () => {
        const list = req.result as TodoList | undefined;
        if (list) t.objectStore(LIST_STORE).put({ ...list, deletedAt, updatedAt: deletedAt });
      };
    });
  }

  async clear(): Promise<void> {
    const db = await this.getDB();
    await tx(db, [TODO_STORE, LIST_STORE], 'readwrite', (t) => {
      t.objectStore(TODO_STORE).clear();
      t.objectStore(LIST_STORE).clear();
    });
  }

  close(): void {
    this.dbPromise?.then((db) => db.close()).catch(() => {});
    this.dbPromise = null;
  }
}
