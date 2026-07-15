import { useEffect, useMemo, useState, type ReactNode } from 'react';
import {
  useTodoStore,
  IndexedDBStorage,
  SyncEngine,
  generateId as generateDeviceId,
  selectActiveTodos,
  selectCompletedTodos,
  offlineQueue,
  type Todo,
} from '@woo-todo/core';
import {
  TodoList,
  AddTodoInput,
  EmptyState,
  ListSwitcher,
  SearchBar,
  matchesSearch,
  ThemeToggle,
  useTheme,
  exportTodosAsJson,
  exportTodosAsCsv,
  downloadFile,
  colors as defaultColors,
  spacing,
  radii,
} from '@woo-todo/ui';
import { TitleBar } from './components/TitleBar';
import { useWindowState } from './hooks/useWindowState';
import './styles/global.css';

const DEVICE_ID_KEY = 'woo-todo:device-id';
const SERVER_URL = (import.meta.env.VITE_SYNC_SERVER_URL as string | undefined) ?? 'http://localhost:3001';

function getOrCreateDeviceId(): string {
  let id = localStorage.getItem(DEVICE_ID_KEY);
  if (!id) {
    id = generateDeviceId();
    localStorage.setItem(DEVICE_ID_KEY, id);
  }
  return id;
}

export function App(): ReactNode {
  const [{ alwaysOnTop, penetrate }, windowApi] = useWindowState();
  const [ready, setReady] = useState(false);
  const [query, setQuery] = useState('');
  const [showSettings, setShowSettings] = useState(false);
  const [theme, setThemeMode] = useTheme();
  const colors = theme.colors;

  const allTodos = useTodoStore(selectActiveTodos);
  const allCompleted = useTodoStore(selectCompletedTodos);
  const lists = useTodoStore((s) => s.lists);
  const activeListId = useTodoStore((s) => s.activeListId);
  const setActiveList = useTodoStore((s) => s.setActiveList);
  const addList = useTodoStore((s) => s.addList);
  const deleteList = useTodoStore((s) => s.deleteList);

  useEffect(() => {
    void (async () => {
      const storage = new IndexedDBStorage();
      const deviceId = getOrCreateDeviceId();
      await useTodoStore.getState().init(storage, deviceId);

      const engine = new SyncEngine({ serverUrl: SERVER_URL, deviceId });
      engine.start();
      void engine.flushQueue();

      setReady(true);
    })();
  }, []);

  useEffect(() => {
    function onKey(e: KeyboardEvent): void {
      const meta = e.metaKey || e.ctrlKey;
      if (meta && e.shiftKey && e.key.toLowerCase() === 't') {
        e.preventDefault();
        void windowApi.toggleAlwaysOnTop();
      } else if (meta && e.shiftKey && e.key.toLowerCase() === 'g') {
        e.preventDefault();
        void windowApi.togglePenetrate();
      } else if (meta && e.key.toLowerCase() === 'n') {
        e.preventDefault();
        const input = document.querySelector<HTMLInputElement>('input[placeholder*="新增"]');
        input?.focus();
      } else if (meta && e.key.toLowerCase() === 'k') {
        e.preventDefault();
        setShowSettings((v) => !v);
      }
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [windowApi]);

  const todos = useMemo(() => filterByQuery(allTodos, query), [allTodos, query]);
  const completed = useMemo(() => filterByQuery(allCompleted, query), [allCompleted, query]);
  const allTodoRecords = useTodoStore((s) => s.todos);
  const allListRecords = useTodoStore((s) => s.lists);

  const currentList = lists[activeListId];
  const hasContent = allTodos.length + allCompleted.length > 0;

  if (!ready) {
    return (
      <div
        style={{
          width: '100vw',
          height: '100vh',
          background: colors.bg,
          borderRadius: 16,
          backdropFilter: 'blur(20px)',
          WebkitBackdropFilter: 'blur(20px)',
        }}
      />
    );
  }

  return (
    <div
      style={{
        width: '100vw',
        height: '100vh',
        background: colors.bg,
        borderRadius: 16,
        border: `1px solid ${colors.border}`,
        backdropFilter: 'blur(20px)',
        WebkitBackdropFilter: 'blur(20px)',
        boxShadow: '0 12px 36px rgba(0, 0, 0, 0.45)',
        display: 'flex',
        flexDirection: 'column',
        overflow: 'hidden',
        pointerEvents: penetrate ? 'none' : 'auto',
        color: colors.text,
      }}
    >
      <TitleBar
        title={currentList?.name ?? 'woo-todo'}
        alwaysOnTop={alwaysOnTop}
        penetrate={penetrate}
        onToggleTop={() => void windowApi.toggleAlwaysOnTop()}
        onTogglePenetrate={() => void windowApi.togglePenetrate()}
        onOpenSettings={() => setShowSettings((v) => !v)}
      />

      <div style={{ display: 'flex', flex: 1, minHeight: 0 }}>
        {!penetrate && showSettings && (
          <aside
            style={{
              width: 160,
              borderRight: `1px solid ${colors.border}`,
              background: 'rgba(0,0,0,0.12)',
              display: 'flex',
              flexDirection: 'column',
              pointerEvents: 'auto',
            }}
          >
            <ListSwitcher
              lists={Object.values(lists).filter((l) => !l.deletedAt).sort((a, b) => a.order - b.order)}
              activeListId={activeListId}
              onSelect={setActiveList}
              onAdd={addList}
              onDelete={deleteList}
            />
            <div style={{ flex: 1 }} />
            <div
              style={{
                padding: spacing.sm,
                borderTop: `1px solid ${colors.border}`,
                display: 'flex',
                flexDirection: 'column',
                gap: 8,
              }}
            >
              <ThemeToggle mode={theme.mode} onChange={setThemeMode} />
              <ExportButton
                onExport={(fmt) => {
                  const all = Object.values(allTodoRecords).filter((t) => !t.deletedAt);
                  const ls = Object.values(allListRecords);
                  if (fmt === 'json') {
                    downloadFile(
                      `woo-todo-${Date.now()}.json`,
                      exportTodosAsJson(all, ls),
                      'application/json'
                    );
                  } else {
                    downloadFile(
                      `woo-todo-${Date.now()}.csv`,
                      exportTodosAsCsv(all),
                      'text/csv'
                    );
                  }
                }}
              />
            </div>
          </aside>
        )}

        <main style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
          {!penetrate && (
            <div style={{ padding: `${spacing.sm}px ${spacing.md}px 0` }}>
              <SearchBar value={query} onChange={setQuery} placeholder="搜索待办、标签…" />
            </div>
          )}

          <div
            style={{
              flex: 1,
              overflowY: 'auto',
              padding: `${spacing.sm}px 0`,
              pointerEvents: penetrate ? 'none' : 'auto',
            }}
          >
            {!hasContent && !penetrate ? (
              <EmptyState />
            ) : (
              <>
                {todos.length > 0 && (
                  <TodoList
                    title="待办"
                    todos={todos}
                    onToggle={(id) => useTodoStore.getState().toggleTodo(id)}
                    onDelete={(id) => {
                      const t = useTodoStore.getState().todos[id];
                      useTodoStore.getState().deleteTodo(id);
                      if (t) offlineQueue.enqueue({ deletedTodoId: id });
                    }}
                    onUpdate={(id, patch) => {
                      useTodoStore.getState().updateTodo(id, patch);
                      const updated = useTodoStore.getState().todos[id];
                      if (updated) offlineQueue.enqueue({ todo: updated });
                    }}
                  />
                )}
                {completed.length > 0 && !query && (
                  <TodoList
                    title="已完成"
                    todos={completed}
                    onToggle={(id) => useTodoStore.getState().toggleTodo(id)}
                    onDelete={(id) => {
                      useTodoStore.getState().deleteTodo(id);
                      offlineQueue.enqueue({ deletedTodoId: id });
                    }}
                    onUpdate={(id, patch) => {
                      useTodoStore.getState().updateTodo(id, patch);
                      const updated = useTodoStore.getState().todos[id];
                      if (updated) offlineQueue.enqueue({ todo: updated });
                    }}
                  />
                )}
                {penetrate && <PenetrateOnlyView todos={todos} completed={completed} colors={colors} />}
              </>
            )}
          </div>

          {!penetrate && (
            <div
              style={{
                padding: spacing.md,
                borderTop: `1px solid ${colors.border}`,
                background: 'rgba(20, 20, 22, 0.4)',
              }}
            >
              <AddTodoInput
                onAdd={(content, options) => {
                  const t = useTodoStore.getState().addTodo({
                    content,
                    listId: activeListId,
                    priority: options?.priority ?? 0,
                    dueDate: options?.dueDate,
                  });
                  offlineQueue.enqueue({ todo: t });
                }}
              />
            </div>
          )}
        </main>
      </div>
    </div>
  );
}

function filterByQuery(items: Todo[], query: string): Todo[] {
  if (!query.trim()) return items;
  return items.filter((t) => matchesSearch(t, query.trim()));
}

function ExportButton({ onExport }: { onExport: (fmt: 'json' | 'csv') => void }): ReactNode {
  return (
    <div style={{ display: 'flex', gap: 4 }}>
      <button
        onClick={() => onExport('json')}
        style={settingsBtnStyle}
        title="导出 JSON"
      >
        JSON
      </button>
      <button
        onClick={() => onExport('csv')}
        style={settingsBtnStyle}
        title="导出 CSV"
      >
        CSV
      </button>
    </div>
  );
}

const settingsBtnStyle = {
  flex: 1,
  padding: '4px 8px',
  fontSize: 11,
  background: 'transparent',
  border: `1px solid ${defaultColors.border}`,
  borderRadius: radii.sm,
  color: defaultColors.textMuted,
  cursor: 'pointer',
} as const;

function PenetrateOnlyView({
  todos,
  completed,
  colors,
}: {
  todos: Todo[];
  completed: Todo[];
  colors: typeof defaultColors;
}): ReactNode {
  if (todos.length === 0 && completed.length === 0) {
    return (
      <div
        style={{
          textAlign: 'center',
          color: 'rgba(255,255,255,0.6)',
          fontSize: 16,
          textShadow: '0 1px 2px rgba(0,0,0,0.6)',
          padding: spacing.xl,
        }}
      >
        ✨
      </div>
    );
  }
  return (
    <div style={{ padding: `${spacing.sm}px ${spacing.lg}px`, fontSize: 14, lineHeight: 1.6 }}>
      {todos.map((t) => (
        <div
          key={t.id}
          style={{
            color: colors.text,
            textShadow: '0 1px 2px rgba(0,0,0,0.7)',
            marginBottom: 4,
          }}
        >
          ○ {t.content}
        </div>
      ))}
      {completed.map((t) => (
        <div
          key={t.id}
          style={{
            color: colors.textFaint,
            textDecoration: 'line-through',
            textShadow: '0 1px 2px rgba(0,0,0,0.5)',
            marginBottom: 4,
          }}
        >
          ● {t.content}
        </div>
      ))}
    </div>
  );
}
