import { WebSocketServer, type WebSocket } from 'ws';
import type { IncomingMessage } from 'node:http';
import { db, getServerTime } from '../db/index.js';
import { todoRepo, listRepo } from '../db/repos.js';
import { broadcast } from './broadcast.js';
import type { Todo, TodoList, ClientMessage, SyncPullResponse, SyncAck } from '@woo-todo/core';

function parseTodo(json: string): Todo {
  return JSON.parse(json) as Todo;
}

function parseList(json: string): TodoList {
  return JSON.parse(json) as TodoList;
}

function touchDevice(deviceId: string): void {
  db.prepare('INSERT OR REPLACE INTO devices (device_id, last_seen_at) VALUES (?, ?)').run(deviceId, getServerTime());
}

export function attachWebSocket(wss: WebSocketServer): void {
  wss.on('connection', (ws: WebSocket, _req: IncomingMessage) => {
    broadcast.add(ws);

    ws.on('message', (raw) => {
      let msg: ClientMessage;
      try {
        msg = JSON.parse(raw.toString()) as ClientMessage;
      } catch {
        return;
      }

      if (msg.type === 'pull') {
        const since = msg.since ?? 0;
        const todos = todoRepo.getSince(since).map((r) => parseTodo(r.data));
        const lists = listRepo.getSince(since).map((r) => parseList(r.data));
        const deletedTodoIds = todoRepo.getSince(since).filter((r) => r.deleted_at != null).map((r) => r.id);
        const deletedListIds = listRepo.getSince(since).filter((r) => r.deleted_at != null).map((r) => r.id);

        const resp: SyncPullResponse = {
          type: 'pull-response',
          todos,
          lists,
          deletedTodoIds,
          deletedListIds,
          serverTime: getServerTime(),
        };
        ws.send(JSON.stringify(resp));
        return;
      }

      if (msg.type === 'sync') {
        touchDevice(msg.deviceId);
        const serverTime = getServerTime();
        const acceptedTodos: Todo[] = [];
        const acceptedLists: TodoList[] = [];
        const deletedTodoIds: string[] = [];
        const deletedListIds: string[] = [];

        const upsertTodoStmt = db.prepare(
          `INSERT INTO todos (id, data, updated_at, deleted_at)
           VALUES (@id, @data, @updated_at, @deleted_at)
           ON CONFLICT(id) DO UPDATE SET
             data = excluded.data,
             updated_at = excluded.updated_at,
             deleted_at = excluded.deleted_at
           WHERE excluded.updated_at > todos.updated_at`
        );
        const getTodoStmt = db.prepare('SELECT data, updated_at, deleted_at FROM todos WHERE id = ?');

        const upsertTodo = db.transaction((rows: Todo[]) => {
          for (const t of rows) {
            const existing = getTodoStmt.get(t.id) as { data: string; updated_at: number } | undefined;
            if (!existing || existing.updated_at < t.updatedAt) {
              upsertTodoStmt.run({
                id: t.id,
                data: JSON.stringify(t),
                updated_at: t.updatedAt,
                deleted_at: t.deletedAt ?? null,
              });
              acceptedTodos.push(t);
            }
          }
        });
        upsertTodo(msg.todos);

        const upsertListStmt = db.prepare(
          `INSERT INTO lists (id, data, updated_at, deleted_at)
           VALUES (@id, @data, @updated_at, @deleted_at)
           ON CONFLICT(id) DO UPDATE SET
             data = excluded.data,
             updated_at = excluded.updated_at,
             deleted_at = excluded.deleted_at
           WHERE excluded.updated_at > lists.updated_at`
        );
        const getListStmt = db.prepare('SELECT data, updated_at, deleted_at FROM lists WHERE id = ?');

        const upsertList = db.transaction((rows: TodoList[]) => {
          for (const l of rows) {
            const existing = getListStmt.get(l.id) as { data: string; updated_at: number } | undefined;
            if (!existing || existing.updated_at < l.updatedAt) {
              upsertListStmt.run({
                id: l.id,
                data: JSON.stringify(l),
                updated_at: l.updatedAt,
                deleted_at: l.deletedAt ?? null,
              });
              acceptedLists.push(l);
            }
          }
        });
        upsertList(msg.lists);

        const softDeleteTodoStmt = db.prepare(
          'UPDATE todos SET deleted_at = ?, updated_at = ?, data = ? WHERE id = ? AND deleted_at IS NULL'
        );
        const getTodoForDeleteStmt = db.prepare('SELECT data FROM todos WHERE id = ? AND deleted_at IS NULL');

        for (const id of msg.deletedTodoIds) {
          const existing = getTodoForDeleteStmt.get(id) as { data: string } | undefined;
          if (existing) {
            const t = parseTodo(existing.data);
            const now = Date.now();
            softDeleteTodoStmt.run(now, now, JSON.stringify({ ...t, deletedAt: now, updatedAt: now }), id);
            deletedTodoIds.push(id);
          }
        }

        const softDeleteListStmt = db.prepare(
          'UPDATE lists SET deleted_at = ?, updated_at = ?, data = ? WHERE id = ? AND deleted_at IS NULL'
        );
        const getListForDeleteStmt = db.prepare('SELECT data FROM lists WHERE id = ? AND deleted_at IS NULL');

        for (const id of msg.deletedListIds) {
          const existing = getListForDeleteStmt.get(id) as { data: string } | undefined;
          if (existing) {
            const l = parseList(existing.data);
            const now = Date.now();
            softDeleteListStmt.run(now, now, JSON.stringify({ ...l, deletedAt: now, updatedAt: now }), id);
            deletedListIds.push(id);
          }
        }

        const ack: SyncAck = {
          type: 'ack',
          serverTime,
          accepted: acceptedTodos.length + acceptedLists.length,
          rejected: msg.todos.length + msg.lists.length - acceptedTodos.length - acceptedLists.length,
        };
        ws.send(JSON.stringify(ack));

        if (acceptedTodos.length || acceptedLists.length || deletedTodoIds.length || deletedListIds.length) {
          broadcast.broadcast(msg.deviceId, acceptedTodos, acceptedLists, deletedTodoIds, deletedListIds, serverTime);
        }
      }
    });

    ws.on('close', () => broadcast.remove(ws));
    ws.on('error', () => broadcast.remove(ws));
  });
}
