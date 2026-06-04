// 跨端共享类型定义
// 供 macOS (TypeScript) 和 Android (Kotlin) 参考

export interface Todo {
  id: string
  title: string
  completed: boolean
  createdAt: number    // Unix timestamp ms
  updatedAt: number    // Unix timestamp ms
  isDeleted: boolean
}

export interface SyncMessage {
  type: 'sync' | 'update' | 'ack' | 'connected'
  todos: Todo[]
  lastSyncAt?: number
  serverTime: number
  syncedIds?: string[]
  deletedId?: string
}

export type TodoCreateInput = Pick<Todo, 'title'> & Partial<Pick<Todo, 'id' | 'completed'>>
export type TodoUpdateInput = Partial<Pick<Todo, 'title' | 'completed' | 'isDeleted'>> & { id: string }
