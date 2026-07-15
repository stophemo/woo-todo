import type { Todo, TodoList } from '../types/todo.js';

/**
 * 存储适配器接口 - 桌面端用 IndexedDB，移动端用 SQLite
 * 统一 CRUD 接口 + 变更订阅
 */

export interface StorageAdapter {
  // 初始化（建表/建库）
  init(): Promise<void>;

  // Todos
  getAllTodos(): Promise<Todo[]>;
  getTodo(id: string): Promise<Todo | null>;
  upsertTodos(todos: Todo[]): Promise<void>;
  softDeleteTodo(id: string, deletedAt: number): Promise<void>;
  hardDeleteTodo(id: string): Promise<void>;

  // Lists
  getAllLists(): Promise<TodoList[]>;
  upsertLists(lists: TodoList[]): Promise<void>;
  softDeleteList(id: string, deletedAt: number): Promise<void>;

  // 通用
  clear(): Promise<void>;
  close(): void;
}
