/**
 * useTodo - 跨端共享的核心操作 hook
 * 包装 store 暴露常用操作，自动同步离线队列
 */

import { useCallback } from 'react';
import {
  useTodoStore,
  selectActiveTodos,
  selectCompletedTodos,
  selectActiveLists,
  SyncEngine,
} from '@woo-todo/core';
import { offlineQueue } from '@woo-todo/core';

export function useTodo() {
  const activeTodos = useTodoStore(selectActiveTodos);
  const completedTodos = useTodoStore(selectCompletedTodos);
  const lists = useTodoStore(selectActiveLists);
  const activeListId = useTodoStore((s) => s.activeListId);
  const deviceId = useTodoStore((s) => s.deviceId);

  const addTodo = useTodoStore((s) => s.addTodo);
  const toggleTodo = useTodoStore((s) => s.toggleTodo);
  const deleteTodo = useTodoStore((s) => s.deleteTodo);
  const updateTodo = useTodoStore((s) => s.updateTodo);
  const setActiveList = useTodoStore((s) => s.setActiveList);
  const addList = useTodoStore((s) => s.addList);

  const addTodoAndEnqueue = useCallback(
    (content: string) => {
      const todo = addTodo({ content, listId: activeListId });
      // 推入离线队列（SyncEngine 会在连接时 flush）
      offlineQueue.enqueue({ todo });
      return todo;
    },
    [addTodo, activeListId]
  );

  const toggleAndEnqueue = useCallback(
    (id: string) => {
      toggleTodo(id);
      const updated = useTodoStore.getState().todos[id];
      if (updated) offlineQueue.enqueue({ todo: updated });
    },
    [toggleTodo]
  );

  const deleteAndEnqueue = useCallback(
    (id: string) => {
      deleteTodo(id);
      offlineQueue.enqueue({ deletedTodoId: id });
    },
    [deleteTodo]
  );

  return {
    todos: activeTodos,
    completed: completedTodos,
    lists,
    activeListId,
    deviceId,
    addTodo: addTodoAndEnqueue,
    toggle: toggleAndEnqueue,
    remove: deleteAndEnqueue,
    update: updateTodo,
    setActiveList,
    addList,
  };
}

export type { SyncEngine };
