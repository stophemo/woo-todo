import { type ReactNode } from 'react';
import { TodoItem, type TodoItemProps } from './TodoItem.js';
import { spacing, type Style } from '../constants/theme.js';
import type { Todo } from '@woo-todo/core';

export interface TodoListProps {
  title: string;
  todos: Todo[];
  emptyText?: string;
  onToggle: (id: string) => void;
  onDelete: (id: string) => void;
  onUpdate?: TodoItemProps['onUpdate'];
  onPress?: TodoItemProps['onPress'];
  style?: Style;
}

export function TodoList({ title, todos, emptyText = '暂无待办', onToggle, onDelete, onUpdate, onPress, style }: TodoListProps): ReactNode {
  if (todos.length === 0) return null;
  return (
    <section style={{ marginBottom: spacing.md, ...style }}>
      <h3
        style={{
          margin: `${spacing.sm}px ${spacing.md}px`,
          fontSize: 11,
          fontWeight: 600,
          letterSpacing: 0.6,
          textTransform: 'uppercase',
          color: 'rgba(255, 255, 255, 0.4)',
        }}
      >
        {title} <span style={{ color: 'rgba(255, 255, 255, 0.25)' }}>· {todos.length}</span>
      </h3>
      <ul style={{ listStyle: 'none', margin: 0, padding: 0 }}>
        {todos.map((t) => (
          <li key={t.id}>
            <TodoItem todo={t} onToggle={onToggle} onDelete={onDelete} onUpdate={onUpdate} onPress={onPress} />
          </li>
        ))}
      </ul>
    </section>
  );
}
