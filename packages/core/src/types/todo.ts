/**
 * Todo 数据模型 - 跨端共享类型
 * 兼容 CRDT 同步（向量时钟） + 多端离线编辑
 */

export type Priority = 0 | 1 | 2 | 3; // 0=无 1=低 2=中 3=高

export interface VectorClock {
  [deviceId: string]: number;
}

export interface Todo {
  id: string; // 雪花ID，客户端生成
  content: string;
  completed: boolean;
  listId: string; // 所属列表
  order: number; // fractional indexing 用于排序
  tags: string[];
  priority: Priority;
  dueDate?: number; // 截止时间戳 (ms)
  note?: string; // 备注
  createdAt: number;
  updatedAt: number;
  deletedAt?: number; // 软删除
  vectorClock: VectorClock; // CRDT 向量时钟
}

export interface TodoList {
  id: string;
  name: string;
  color?: string;
  icon?: string;
  order: number;
  createdAt: number;
  updatedAt: number;
  vectorClock: VectorClock;
}

export interface Tag {
  id: string;
  name: string;
  color?: string;
  createdAt: number;
}

/** 创建 Todo 时的输入（id/createdAt 等由 core 生成） */
export type TodoInput = Omit<
  Todo,
  'id' | 'createdAt' | 'updatedAt' | 'vectorClock' | 'deletedAt'
> & { id?: string };
