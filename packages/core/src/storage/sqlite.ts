/**
 * SQLite 存储适配器 - 移动端 (expo-sqlite)
 * 适配器通过注入 sqlExecutor 函数实现，避免直接依赖 expo-sqlite
 */

import type { Todo, TodoList } from '../types/todo.js';
import type { StorageAdapter } from './interface.js';

/** SQLite 执行器接口 - 由宿主注入 expo-sqlite */
export interface SqlExecutor {
  exec(sql: string, params?: unknown[]): Promise<{ rows: { _array: unknown[] }; rowsAffected: number; insertId?: number }>;
  run(sql: string, params?: unknown[]): Promise<{ rowsAffected: number; insertId?: number }>;
  query<T = unknown>(sql: string, params?: unknown[]): Promise<T[]>;
}

export class SqliteStorage implements StorageAdapter {
  constructor(private sql: SqlExecutor) {}

  async init(): Promise<void> {
    await this.sql.exec(`
      CREATE TABLE IF NOT EXISTS todos (
        id TEXT PRIMARY KEY,
        data TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_todos_updated ON todos(json_extract(data, '$.updatedAt'));

      CREATE TABLE IF NOT EXISTS lists (
        id TEXT PRIMARY KEY,
        data TEXT NOT NULL
      );
    `);
  }

  async getAllTodos(): Promise<Todo[]> {
    const rows = await this.sql.query<{ data: string }>('SELECT data FROM todos');
    return rows.map((r) => JSON.parse(r.data) as Todo);
  }

  async getTodo(id: string): Promise<Todo | null> {
    const rows = await this.sql.query<{ data: string }>('SELECT data FROM todos WHERE id = ?', [id]);
    return rows[0] ? (JSON.parse(rows[0].data) as Todo) : null;
  }

  async upsertTodos(todos: Todo[]): Promise<void> {
    for (const todo of todos) {
      await this.sql.run(
        'INSERT OR REPLACE INTO todos (id, data) VALUES (?, ?)',
        [todo.id, JSON.stringify(todo)]
      );
    }
  }

  async softDeleteTodo(id: string, deletedAt: number): Promise<void> {
    const existing = await this.getTodo(id);
    if (!existing) return;
    await this.upsertTodos([{ ...existing, deletedAt, updatedAt: deletedAt }]);
  }

  async hardDeleteTodo(id: string): Promise<void> {
    await this.sql.run('DELETE FROM todos WHERE id = ?', [id]);
  }

  async getAllLists(): Promise<TodoList[]> {
    const rows = await this.sql.query<{ data: string }>('SELECT data FROM lists');
    return rows.map((r) => JSON.parse(r.data) as TodoList);
  }

  async upsertLists(lists: TodoList[]): Promise<void> {
    for (const list of lists) {
      await this.sql.run(
        'INSERT OR REPLACE INTO lists (id, data) VALUES (?, ?)',
        [list.id, JSON.stringify(list)]
      );
    }
  }

  async softDeleteList(id: string, deletedAt: number): Promise<void> {
    const rows = await this.sql.query<{ data: string }>('SELECT data FROM lists WHERE id = ?', [id]);
    if (rows[0]) {
      const list = JSON.parse(rows[0].data) as TodoList;
      await this.upsertLists([{ ...list, deletedAt, updatedAt: deletedAt }]);
    }
  }

  async clear(): Promise<void> {
    await this.sql.run('DELETE FROM todos');
    await this.sql.run('DELETE FROM lists');
  }

  close(): void {
    // expo-sqlite 连接由宿主管理
  }
}
