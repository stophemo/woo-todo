import { Router, type Request, type Response } from 'express';
import { todoRepo, listRepo } from '../db/repos.js';
import { getServerTime } from '../db/index.js';
import type { Todo, TodoList, SyncMessage } from '@woo-todo/core';

export const todosRouter = Router();

// GET /api/todos?since=<timestamp> 增量拉取
todosRouter.get('/', (req: Request, res: Response) => {
  const since = Number(req.query.since ?? 0);
  if (Number.isNaN(since) || since < 0) {
    res.status(400).json({ error: 'invalid since parameter' });
    return;
  }
  const todos = todoRepo.getSince(since).map((r) => JSON.parse(r.data) as Todo);
  const lists = listRepo.getSince(since).map((r) => JSON.parse(r.data) as TodoList);
  const deletedTodoIds = todoRepo.getSince(since).filter((r) => r.deleted_at != null).map((r) => r.id);
  const deletedListIds = listRepo.getSince(since).filter((r) => r.deleted_at != null).map((r) => r.id);
  res.json({
    todos,
    lists,
    deletedTodoIds,
    deletedListIds,
    serverTime: getServerTime(),
  });
});

// POST /api/todos 批量提交变更
todosRouter.post('/', (req: Request, res: Response) => {
  const body = req.body as Partial<SyncMessage>;
  if (!body || !Array.isArray(body.todos) || !Array.isArray(body.lists)) {
    res.status(400).json({ error: 'invalid body' });
    return;
  }
  // 服务端 REST 仅做落库 + 时间戳返回，广播走 WebSocket 通道
  for (const t of body.todos) {
    todoRepo.upsert({
      id: t.id,
      data: JSON.stringify(t),
      updated_at: t.updatedAt,
      deleted_at: t.deletedAt ?? null,
    });
  }
  for (const l of body.lists) {
    listRepo.upsert({
      id: l.id,
      data: JSON.stringify(l),
      updated_at: l.updatedAt,
      deleted_at: l.deletedAt ?? null,
    });
  }
  res.json({ syncedIds: [...body.todos.map((t) => t.id), ...body.lists.map((l) => l.id)], serverTime: getServerTime() });
});
