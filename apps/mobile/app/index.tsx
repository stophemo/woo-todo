/**
 * App 初始化 - 移动端入口
 * 初始化 store、storage、sync engine
 */

import { useEffect, useState, type ReactNode } from 'react';
import { useTodoStore, SyncEngine, offlineQueue, selectActiveTodos, selectCompletedTodos } from '@woo-todo/core';
import { EmptyState, colors, spacing } from '@woo-todo/ui';
import { View, Text, TextInput, FlatList, TouchableOpacity, StyleSheet, Platform } from 'react-native';
import { getMobileStorage } from '../src/services/storage';
import { getOrCreateDeviceId } from '../src/services/device';

const SERVER_URL = process.env.EXPO_PUBLIC_SYNC_SERVER_URL ?? 'http://10.0.2.2:3001';

export default function HomeScreen(): ReactNode {
  const [ready, setReady] = useState(false);
  const todos = useTodoStore(selectActiveTodos);
  const completed = useTodoStore(selectCompletedTodos);
  const activeListId = useTodoStore((s) => s.activeListId);
  const lists = useTodoStore((s) => s.lists);

  useEffect(() => {
    void (async () => {
      const storage = await getMobileStorage();
      const deviceId = await getOrCreateDeviceId();
      await useTodoStore.getState().init(storage, deviceId);

      const engine = new SyncEngine({ serverUrl: SERVER_URL, deviceId });
      engine.start();
      void engine.flushQueue();

      setReady(true);
    })();
  }, []);

  if (!ready) {
    return <View style={styles.loading}><Text style={styles.loadingText}>加载中…</Text></View>;
  }

  const currentList = lists[activeListId];

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <Text style={styles.title}>{currentList?.name ?? 'woo-todo'}</Text>
        <Text style={styles.subtitle}>
          {todos.filter((t) => !t.completed).length} 项待办
        </Text>
      </View>

      <FlatList
        data={[
          ...todos.map((t) => ({ ...t, _section: 'active' as const })),
          ...completed.map((t) => ({ ...t, _section: 'completed' as const })),
        ]}
        keyExtractor={(item) => item.id}
        ListEmptyComponent={<EmptyState />}
        renderItem={({ item }) => {
          const t = item as typeof todos[number] & { _section: 'active' | 'completed' };
          return (
            <TouchableOpacity
              onPress={() => useTodoStore.getState().toggleTodo(t.id)}
              onLongPress={() => useTodoStore.getState().deleteTodo(t.id)}
              style={[styles.todoRow, t.completed && styles.todoRowDone]}
            >
              <View style={[styles.checkbox, t.completed && styles.checkboxDone]}>
                {t.completed ? <Text style={styles.checkMark}>✓</Text> : null}
              </View>
              <Text style={[styles.todoText, t.completed && styles.todoTextDone]} numberOfLines={2}>
                {t.content}
              </Text>
            </TouchableOpacity>
          );
        }}
        contentContainerStyle={{ paddingBottom: 80 }}
      />

      <View style={styles.footer}>
        <MobileAddInput
          onAdd={(content) => {
            const t = useTodoStore.getState().addTodo({ content, listId: activeListId });
            offlineQueue.enqueue({ todo: t });
          }}
        />
      </View>
    </View>
  );
}

function MobileAddInput({ onAdd }: { onAdd: (content: string) => void }): ReactNode {
  const [text, setText] = useState('');
  return (
    <View style={styles.inputRow}>
      <TextInput
        style={styles.input}
        placeholder="新增待办…"
        placeholderTextColor={colors.textMuted}
        value={text}
        onChangeText={setText}
        onSubmitEditing={() => {
          const v = text.trim();
          if (!v) return;
          onAdd(v);
          setText('');
        }}
        returnKeyType="done"
      />
      <TouchableOpacity
        style={[styles.addBtn, !text.trim() && styles.addBtnDisabled]}
        disabled={!text.trim()}
        onPress={() => {
          const v = text.trim();
          if (!v) return;
          onAdd(v);
          setText('');
        }}
      >
        <Text style={styles.addBtnText}>添加</Text>
      </TouchableOpacity>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.bgSolid, paddingTop: Platform.select({ ios: 60, android: 40 }) },
  loading: { flex: 1, backgroundColor: colors.bgSolid, alignItems: 'center', justifyContent: 'center' },
  loadingText: { color: colors.textMuted, fontSize: 14 },
  header: { paddingHorizontal: spacing.lg, paddingBottom: spacing.md },
  title: { fontSize: 24, fontWeight: 700, color: colors.text, marginBottom: 2 },
  subtitle: { fontSize: 12, color: colors.textMuted },
  todoRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: spacing.md,
    paddingHorizontal: spacing.lg,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.border,
  },
  todoRowDone: { opacity: 0.5 },
  checkbox: {
    width: 22,
    height: 22,
    borderRadius: 11,
    borderWidth: 1.5,
    borderColor: 'rgba(255,255,255,0.5)',
    marginRight: spacing.md,
    alignItems: 'center',
    justifyContent: 'center',
  },
  checkboxDone: { backgroundColor: colors.success, borderColor: colors.success },
  checkMark: { color: 'white', fontWeight: '700', fontSize: 13 },
  todoText: { color: colors.text, fontSize: 15, flex: 1 },
  todoTextDone: { textDecorationLine: 'line-through', color: colors.textFaint },
  footer: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    padding: spacing.md,
    backgroundColor: 'rgba(20,20,22,0.95)',
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colors.border,
  },
  inputRow: { flexDirection: 'row', gap: spacing.sm },
  input: {
    flex: 1,
    backgroundColor: colors.surfaceHigh,
    color: colors.text,
    paddingHorizontal: spacing.md,
    paddingVertical: 12,
    borderRadius: 10,
    fontSize: 15,
  },
  addBtn: {
    paddingHorizontal: spacing.lg,
    backgroundColor: colors.accentHigh,
    borderRadius: 10,
    justifyContent: 'center',
  },
  addBtnDisabled: { opacity: 0.4 },
  addBtnText: { color: 'white', fontSize: 14, fontWeight: 600 },
});
