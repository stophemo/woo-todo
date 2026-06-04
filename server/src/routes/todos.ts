import { Router, Request, Response } from 'express'
import { getDb, TodoRow } from '../db'
import { broadcast } from '../sync/websocket'
import { v4 as uuid } from 'uuid'

const router = Router()

interface TodoInput {
  id?: string
  title: string
  completed?: boolean
  isDeleted?: boolean
}

// 获取增量变更
router.get('/', (req: Request, res: Response) => {
  const since = parseInt(req.query.since as string) || 0
  const db = getDb()

  const rows = db
    .prepare('SELECT * FROM todos WHERE updated_at > ? ORDER BY updated_at ASC')
    .all(since) as TodoRow[]

  const todos = rows.map(rowToTodo)
  res.json({ todos, serverTime: Date.now() })
})

// 批量提交变更
router.post('/', (req: Request, res: Response) => {
  const { todos } = req.body as { todos: TodoInput[] }
  const db = getDb()
  const serverTime = Date.now()
  const syncedIds: string[] = []

  const upsert = db.prepare(`
    INSERT INTO todos (id, title, completed, created_at, updated_at, is_deleted)
    VALUES (@id, @title, @completed, @created_at, @updated_at, @is_deleted)
    ON CONFLICT(id) DO UPDATE SET
      title = CASE WHEN @updated_at > updated_at THEN @title ELSE title END,
      completed = CASE WHEN @updated_at > updated_at THEN @completed ELSE completed END,
      is_deleted = CASE WHEN @updated_at > updated_at THEN @is_deleted ELSE is_deleted END,
      updated_at = CASE WHEN @updated_at > updated_at THEN @updated_at ELSE updated_at END
  `)

  const transaction = db.transaction(() => {
    for (const todo of todos) {
      const id = todo.id || uuid()
      upsert.run({
        id,
        title: todo.title,
        completed: todo.completed ? 1 : 0,
        created_at: serverTime,
        updated_at: serverTime,
        is_deleted: todo.isDeleted ? 1 : 0,
      })
      syncedIds.push(id)
    }
  })

  transaction()

  // 广播变更给所有 WebSocket 客户端
  const updatedRows = db
    .prepare('SELECT * FROM todos WHERE id IN (' + syncedIds.map(() => '?').join(',') + ')')
    .all(...syncedIds) as TodoRow[]

  broadcast({
    type: 'update',
    todos: updatedRows.map(rowToTodo),
    serverTime,
  })

  res.json({ syncedIds, serverTime })
})

// 软删除
router.delete('/:id', (req: Request, res: Response) => {
  const db = getDb()
  const serverTime = Date.now()

  db.prepare('UPDATE todos SET is_deleted = 1, updated_at = ? WHERE id = ?').run(serverTime, req.params.id)

  broadcast({ type: 'update', todos: [], serverTime, deletedId: req.params.id })
  res.json({ success: true, serverTime })
})

function rowToTodo(row: TodoRow) {
  return {
    id: row.id,
    title: row.title,
    completed: row.completed === 1,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    isDeleted: row.is_deleted === 1,
  }
}

export default router
