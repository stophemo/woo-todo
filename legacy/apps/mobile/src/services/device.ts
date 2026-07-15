/**
 * 设备 ID 持久化（移动端用 expo-secure-store）
 */
import * as SecureStore from 'expo-secure-store';
import { generateId } from '@woo-todo/core';

const KEY = 'woo-todo-device-id';

export async function getOrCreateDeviceId(): Promise<string> {
  let id: string | null = null;
  try {
    id = await SecureStore.getItemAsync(KEY);
  } catch {
    id = null;
  }
  if (!id) {
    id = generateId();
    try {
      await SecureStore.setItemAsync(KEY, id);
    } catch {
      // 忽略，进程内可用
    }
  }
  return id;
}
