import Database from 'better-sqlite3';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

const DB_PATH = process.env.WOO_TODO_DB ?? resolve(process.cwd(), 'data/woo-todo.db');

mkdirSync(dirname(DB_PATH), { recursive: true });

export const db = new Database(DB_PATH);
db.pragma('journal_mode = WAL');
db.pragma('foreign_keys = ON');

db.exec(`
  CREATE TABLE IF NOT EXISTS todos (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER
  );
  CREATE INDEX IF NOT EXISTS idx_todos_updated ON todos(updated_at);

  CREATE TABLE IF NOT EXISTS lists (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER
  );
  CREATE INDEX IF NOT EXISTS idx_lists_updated ON lists(updated_at);

  CREATE TABLE IF NOT EXISTS devices (
    device_id TEXT PRIMARY KEY,
    last_seen_at INTEGER NOT NULL
  );
`);

export function getServerTime(): number {
  return Date.now();
}
