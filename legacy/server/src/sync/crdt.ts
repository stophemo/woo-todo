/**
 * 服务端 CRDT 合并
 * 收到客户端变更时，比较向量时钟决定接受/拒绝
 * - 远程时钟 > 本地时钟：接受
 * - 并发：合并 fields，向量时钟取 max
 * - 远程时钟 <= 本地时钟：拒绝（本地更新）
 */

import type { Todo, TodoList, VectorClock } from '@woo-todo/core';
import { clockGreater, mergeClocks } from '@woo-todo/core';

export function shouldAccept(remoteClock: VectorClock, localClock: VectorClock | undefined): boolean {
  if (!localClock) return true;
  return clockGreater(remoteClock, localClock);
}

export function mergeTodo(remote: Todo, local: Todo | undefined): Todo {
  if (!local) return remote;
  if (clockGreater(remote.vectorClock, local.vectorClock)) {
    return { ...local, ...remote, vectorClock: mergeClocks(local.vectorClock, remote.vectorClock) };
  }
  // 并发或本地更新：保留本地，合并时钟
  return { ...local, vectorClock: mergeClocks(local.vectorClock, remote.vectorClock) };
}

export function mergeList(remote: TodoList, local: TodoList | undefined): TodoList {
  if (!local) return remote;
  if (clockGreater(remote.vectorClock, local.vectorClock)) {
    return { ...local, ...remote, vectorClock: mergeClocks(local.vectorClock, remote.vectorClock) };
  }
  return { ...local, vectorClock: mergeClocks(local.vectorClock, remote.vectorClock) };
}
