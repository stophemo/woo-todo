/**
 * CRDT 冲突解决 - 向量时钟合并
 * 取代简单 LWW，支持离线并发编辑后自动合并
 */

import type { VectorClock } from '../types/todo.js';

/** 向量时钟合并：取每个设备ID的最大值 */
export function mergeClocks(a: VectorClock, b: VectorClock): VectorClock {
  const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
  const merged: VectorClock = {};
  for (const k of keys) {
    merged[k] = Math.max(a[k] ?? 0, b[k] ?? 0);
  }
  return merged;
}

/** 时钟 a 是否严格大于 b（a 在 b 之后） */
export function clockGreater(a: VectorClock, b: VectorClock): boolean {
  let hasGreater = false;
  const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
  for (const k of keys) {
    const av = a[k] ?? 0;
    const bv = b[k] ?? 0;
    if (av < bv) return false;
    if (av > bv) hasGreater = true;
  }
  return hasGreater;
}

/** 时钟 a 和 b 是否存在并发（a 既不大于 b，b 也不大于 a） */
export function clockConcurrent(a: VectorClock, b: VectorClock): boolean {
  return !clockGreater(a, b) && !clockGreater(b, a);
}

/** 时钟是否相等 */
export function clockEqual(a: VectorClock, b: VectorClock): boolean {
  const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
  for (const k of keys) {
    if ((a[k] ?? 0) !== (b[k] ?? 0)) return false;
  }
  return true;
}

/** 增加本地时钟计数 */
export function tickClock(clock: VectorClock, deviceId: string): VectorClock {
  return { ...clock, [deviceId]: (clock[deviceId] ?? 0) + 1 };
}
