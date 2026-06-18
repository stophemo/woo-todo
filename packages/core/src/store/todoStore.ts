/**
 * TodoStore - 跨端共享状态
 * 单例 Zustand store：todos/lists + CRUD + 同步钩子
 * 存储适配器和同步引擎在初始化时注入
 */

import { create } from 'zustand';
import type { Todo, TodoList, TodoInput, Priority, VectorClock } from '../types/todo.js';
import type { StorageAdapter } from '../storage/interface.js';
import { generateId } from '../utils/id-generator.js';
import { tickClock, mergeClocks, clockGreater } from '../sync/crdt.js';

export interface TodoStoreState {
  deviceId: string;
  todos: Record<string, Todo>;
  lists: Record<string, TodoList>;
  activeListId: string;
  storage: StorageAdapter | null;
  initialized: boolean;
}

export interface TodoStoreActions {
  init(storage: StorageAdapter, deviceId: string): Promise<void>;

  // Lists
  addList(name: string, color?: string): TodoList;
  updateList(id: string, patch: Partial<Omit<TodoList, 'id' | 'createdAt' | 'vectorClock'>>): void;
  deleteList(id: string): void;
  setActiveList(id: string): void;

  // Todos
  addTodo(input: TodoInput): Todo;
  updateTodo(id: string, patch: Partial<Omit<Todo, 'id' | 'createdAt' | 'vectorClock' | 'deletedAt'>>): void;
  toggleTodo(id: string): void;
  deleteTodo(id: string): void;
  reorderTodo(id: string, newOrder: number): void;

  // 同步相关
  applyRemoteTodos(remoteTodos: Todo[], remoteLists: TodoList[], deletedTodoIds: string[], deletedListIds: string[]): void;

  // 工具
  reset(): Promise<void>;
}

export type TodoStore = TodoStoreState & TodoStoreActions;

const DEFAULT_LIST_ID = 'list-inbox';

function createDefaultList(deviceId: string, order: number): TodoList {
  const now = Date.now();
  return {
    id: DEFAULT_LIST_ID,
    name: '收件箱',
    color: '#6366f1',
    icon: 'inbox',
    order,
    createdAt: now,
    updatedAt: now,
    vectorClock: { [deviceId]: 1 },
  };
}

export const useTodoStore = create<TodoStore>((set, get) => ({
  deviceId: '',
  todos: {},
  lists: {},
  activeListId: DEFAULT_LIST_ID,
  storage: null,
  initialized: false,

  async init(storage, deviceId) {
    const existing = get();
    if (existing.initialized) return;

    await storage.init();
    const [todos, lists] = await Promise.all([storage.getAllTodos(), storage.getAllLists()]);

    const todoMap: Record<string, Todo> = {};
    for (const t of todos) todoMap[t.id] = t;

    const listMap: Record<string, TodoList> = {};
    for (const l of lists) listMap[l.id] = l;

    if (Object.keys(listMap).length === 0) {
      const def = createDefaultList(deviceId, 0);
      listMap[def.id] = def;
      await storage.upsertLists([def]);
    }

    set({
      storage,
      deviceId,
      todos: todoMap,
      lists: listMap,
      initialized: true,
      activeListId: Object.keys(listMap)[0] ?? DEFAULT_LIST_ID,
    });
  },

  addList(name, color) {
    const { deviceId, lists, storage } = get();
    const id = generateId();
    const now = Date.now();
    const order = Object.values(lists).length;
    const list: TodoList = {
      id,
      name,
      color: color ?? '#6366f1',
      icon: 'list',
      order,
      createdAt: now,
      updatedAt: now,
      vectorClock: { [deviceId]: 1 },
    };
    set({ lists: { ...lists, [id]: list } });
    void storage?.upsertLists([list]);
    return list;
  },

  updateList(id, patch) {
    const { deviceId, lists, storage } = get();
    const existing = lists[id];
    if (!existing) return;
    const now = Date.now();
    const updated: TodoList = {
      ...existing,
      ...patch,
      updatedAt: now,
      vectorClock: tickClock(existing.vectorClock, deviceId),
    };
    set({ lists: { ...lists, [id]: updated } });
    void storage?.upsertLists([updated]);
  },

  deleteList(id) {
    if (id === DEFAULT_LIST_ID) return; // 保护默认列表
    const { deviceId, lists, storage } = get();
    const existing = lists[id];
    if (!existing) return;
    const now = Date.now();
    const updated: TodoList = {
      ...existing,
      deletedAt: now,
      updatedAt: now,
      vectorClock: tickClock(existing.vectorClock, deviceId),
    };
    set({ lists: { ...lists, [id]: updated } });
    void storage?.softDeleteList(id, now);
  },

  setActiveList(id) {
    set({ activeListId: id });
  },

  addTodo(input) {
    const { deviceId, todos, storage } = get();
    const id = input.id ?? generateId();
    const now = Date.now();
    const todo: Todo = {
      id,
      content: input.content,
      completed: input.completed ?? false,
      listId: input.listId,
      order: input.order ?? now,
      tags: input.tags ?? [],
      priority: (input.priority ?? 0) as Priority,
      dueDate: input.dueDate,
      note: input.note,
      createdAt: now,
      updatedAt: now,
      vectorClock: { [deviceId]: 1 },
    };
    set({ todos: { ...todos, [id]: todo } });
    void storage?.upsertTodos([todo]);
    return todo;
  },

  updateTodo(id, patch) {
    const { deviceId, todos, storage } = get();
    const existing = todos[id];
    if (!existing) return;
    const now = Date.now();
    const updated: Todo = {
      ...existing,
      ...patch,
      updatedAt: now,
      vectorClock: tickClock(existing.vectorClock, deviceId),
    };
    set({ todos: { ...todos, [id]: updated } });
    void storage?.upsertTodos([updated]);
  },

  toggleTodo(id) {
    const { updateTodo, todos } = get();
    const existing = todos[id];
    if (!existing) return;
    updateTodo(id, { completed: !existing.completed });
  },

  deleteTodo(id) {
    const { deviceId, todos, storage } = get();
    const existing = todos[id];
    if (!existing) return;
    const now = Date.now();
    const updated: Todo = {
      ...existing,
      deletedAt: now,
      updatedAt: now,
      vectorClock: tickClock(existing.vectorClock, deviceId),
    };
    set({ todos: { ...todos, [id]: updated } });
    void storage?.softDeleteTodo(id, now);
  },

  reorderTodo(id, newOrder) {
    get().updateTodo(id, { order: newOrder });
  },

  applyRemoteTodos(remoteTodos, remoteLists, deletedTodoIds, deletedListIds) {
    const state = get();
    const newTodos = { ...state.todos };
    const newLists = { ...state.lists };

    for (const remote of remoteTodos) {
      const local = newTodos[remote.id];
      if (!local || clockGreater(remote.vectorClock, local.vectorClock)) {
        newTodos[remote.id] = remote;
      } else if (local) {
        // 并发：CRDT 合并
        newTodos[remote.id] = { ...local, ...remote, vectorClock: mergeClocks(local.vectorClock, remote.vectorClock) };
      }
    }

    for (const id of deletedTodoIds) {
      if (newTodos[id]) {
        newTodos[id] = { ...newTodos[id]!, deletedAt: newTodos[id]!.deletedAt ?? Date.now() };
      }
    }

    for (const remote of remoteLists) {
      const local = newLists[remote.id];
      if (!local || clockGreater(remote.vectorClock, local.vectorClock)) {
        newLists[remote.id] = remote;
      }
    }

    for (const id of deletedListIds) {
      if (newLists[id]) {
        newLists[id] = { ...newLists[id]!, deletedAt: newLists[id]!.deletedAt ?? Date.now() };
      }
    }

    set({ todos: newTodos, lists: newLists });
    void state.storage?.upsertTodos(Object.values(newTodos));
    void state.storage?.upsertLists(Object.values(newLists));
  },

  async reset() {
    const { storage } = get();
    if (storage) await storage.clear();
    set({
      todos: {},
      lists: {},
      activeListId: DEFAULT_LIST_ID,
      initialized: false,
    });
  },
}));

/** 派生：当前列表下的活跃 todo（按 order 升序） */
export function selectActiveTodos(state: TodoStore): Todo[] {
  return Object.values(state.todos)
    .filter((t) => t.listId === state.activeListId && !t.deletedAt)
    .sort((a, b) => a.order - b.order);
}

export function selectCompletedTodos(state: TodoStore): Todo[] {
  return Object.values(state.todos)
    .filter((t) => t.listId === state.activeListId && !t.deletedAt && t.completed)
    .sort((a, b) => b.updatedAt - a.updatedAt);
}

export function selectActiveLists(state: TodoStore): TodoList[] {
  return Object.values(state.lists)
    .filter((l) => !l.deletedAt)
    .sort((a, b) => a.order - b.order);
}
