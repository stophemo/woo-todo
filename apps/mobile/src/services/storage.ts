/**
 * expo-sqlite 适配器 - 把 @woo-todo/core 的 SqliteStorage 接到 expo
 */

import * as SQLite from 'expo-sqlite';
import { SqliteStorage, type SqlExecutor } from '@woo-todo/core';

let _db: SQLite.SQLiteDatabase | null = null;

async function getDb(): Promise<SQLite.SQLiteDatabase> {
  if (_db) return _db;
  _db = await SQLite.openDatabaseAsync('woo-todo.db');
  return _db;
}

function createExecutor(db: SQLite.SQLiteDatabase): SqlExecutor {
  return {
    async exec(sql) {
      await db.execAsync(sql);
      return { rows: { _array: [] }, rowsAffected: 0 };
    },
    async run(sql, params = []) {
      const result = await db.runAsync(sql, params as SQLite.SQLiteBindValue[]);
      return { rowsAffected: result.changes, insertId: result.lastInsertRowId };
    },
    async query(sql, params = []) {
      const rows = await db.getAllAsync(sql, params as SQLite.SQLiteBindValue[]);
      return rows as unknown[];
    },
  };
}

let _storage: SqliteStorage | null = null;

export async function getMobileStorage(): Promise<SqliteStorage> {
  if (_storage) return _storage;
  const db = await getDb();
  const storage = new SqliteStorage(createExecutor(db));
  await storage.init();
  _storage = storage;
  return storage;
}
