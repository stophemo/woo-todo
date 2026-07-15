import { db } from '../index.js';
import type { ServerTodo, ServerList } from '../../types/shared.js';

export const todoRepo = {
  getSince(since: number): ServerTodo[] {
    const rows = db
      .prepare('SELECT id, data, updated_at, deleted_at FROM todos WHERE updated_at > ? ORDER BY updated_at ASC')
      .all(since) as ServerTodo[];
    return rows;
  },

  getAll(): ServerTodo[] {
    return db.prepare('SELECT id, data, updated_at, deleted_at FROM todos ORDER BY updated_at ASC').all() as ServerTodo[];
  },

  upsert(row: ServerTodo): void {
    db.prepare(
      `INSERT INTO todos (id, data, updated_at, deleted_at)
       VALUES (@id, @data, @updated_at, @deleted_at)
       ON CONFLICT(id) DO UPDATE SET
         data = excluded.data,
         updated_at = excluded.updated_at,
         deleted_at = excluded.deleted_at`
    ).run(row);
  },
};

export const listRepo = {
  getSince(since: number): ServerList[] {
    return db
      .prepare('SELECT id, data, updated_at, deleted_at FROM lists WHERE updated_at > ? ORDER BY updated_at ASC')
      .all(since) as ServerList[];
  },

  getAll(): ServerList[] {
    return db.prepare('SELECT id, data, updated_at, deleted_at FROM lists ORDER BY updated_at ASC').all() as ServerList[];
  },

  upsert(row: ServerList): void {
    db.prepare(
      `INSERT INTO lists (id, data, updated_at, deleted_at)
       VALUES (@id, @data, @updated_at, @deleted_at)
       ON CONFLICT(id) DO UPDATE SET
         data = excluded.data,
         updated_at = excluded.updated_at,
         deleted_at = excluded.deleted_at`
    ).run(row);
  },
};
