import { useState, type ReactNode } from 'react';
import { Checkbox } from './Checkbox.js';
import { colors, priorityColors, spacing, radii, type Style } from '../constants/theme.js';
import { formatDueDate, isOverdue, isToday } from '@woo-todo/core';
import type { Todo, Priority } from '@woo-todo/core';

export interface TodoItemProps {
  todo: Todo;
  onToggle: (id: string) => void;
  onDelete: (id: string) => void;
  onUpdate?: (id: string, patch: Partial<Pick<Todo, 'content' | 'priority' | 'dueDate' | 'tags'>>) => void;
  onPress?: (id: string) => void;
  style?: Style;
}

const priorityLabels: Record<Priority, string> = { 0: '', 1: '低', 2: '中', 3: '高' };

export function TodoItem({ todo, onToggle, onDelete, onPress, style }: TodoItemProps): ReactNode {
  const [hovered, setHovered] = useState(false);
  const overdue = isOverdue(todo.dueDate) && !todo.completed;
  const today = isToday(todo.dueDate);
  const dueText = formatDueDate(todo.dueDate);

  return (
    <div
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      onClick={() => onPress?.(todo.id)}
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: spacing.md,
        padding: `${spacing.sm}px ${spacing.md}px`,
        borderRadius: radii.md,
        transition: 'background 0.15s ease',
        background: hovered ? colors.surface : 'transparent',
        cursor: onPress ? 'pointer' : 'default',
        ...style,
      }}
    >
      <Checkbox checked={todo.completed} onChange={() => onToggle(todo.id)} size={20} />
      <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 2 }}>
        <div
          style={{
            fontSize: 14,
            color: todo.completed ? colors.textFaint : colors.text,
            textDecoration: todo.completed ? 'line-through' : 'none',
            overflow: 'hidden',
            textOverflow: 'ellipsis',
            whiteSpace: 'nowrap',
          }}
        >
          {todo.content}
        </div>
        {(dueText || todo.priority > 0 || todo.tags.length > 0) && (
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 11, color: colors.textMuted }}>
            {todo.priority > 0 && (
              <span style={{ color: priorityColors[todo.priority] }}>● {priorityLabels[todo.priority]}</span>
            )}
            {dueText && (
              <span style={{ color: overdue ? colors.danger : today ? colors.warning : colors.textMuted }}>
                {overdue ? '⚠ ' : ''}
                {dueText}
              </span>
            )}
            {todo.tags.map((t) => (
              <span key={t} style={{ color: colors.accent }}>#{t}</span>
            ))}
          </div>
        )}
      </div>
      {hovered && (
        <button
          onClick={(e) => {
            e.stopPropagation();
            onDelete(todo.id);
          }}
          aria-label="删除"
          style={{
            background: 'rgba(255, 80, 80, 0.2)',
            color: colors.danger,
            border: 'none',
            borderRadius: radii.sm,
            padding: `${spacing.xs}px ${spacing.sm}px`,
            fontSize: 12,
            cursor: 'pointer',
          }}
        >
          ✕
        </button>
      )}
    </div>
  );
}
