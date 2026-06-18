import { useState, type ReactNode } from 'react';
import { colors, spacing, radii, type Style } from '../constants/theme.js';
import type { TodoList } from '@woo-todo/core';

export interface ListSwitcherProps {
  lists: TodoList[];
  activeListId: string;
  onSelect: (id: string) => void;
  onAdd: (name: string) => void;
  onDelete?: (id: string) => void;
  style?: Style;
}

export function ListSwitcher({ lists, activeListId, onSelect, onAdd, onDelete, style }: ListSwitcherProps): ReactNode {
  const [adding, setAdding] = useState(false);
  const [name, setName] = useState('');

  function commit(): void {
    const v = name.trim();
    if (!v) {
      setAdding(false);
      return;
    }
    onAdd(v);
    setName('');
    setAdding(false);
  }

  return (
    <div
      style={{
        display: 'flex',
        flexDirection: 'column',
        gap: 2,
        padding: spacing.sm,
        ...style,
      }}
    >
      {lists.map((l) => {
        const active = l.id === activeListId;
        return (
          <div
            key={l.id}
            onClick={() => onSelect(l.id)}
            role="button"
            tabIndex={0}
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 8,
              padding: `6px ${spacing.sm}px`,
              borderRadius: radii.sm,
              cursor: 'pointer',
              background: active ? 'rgba(129, 140, 248, 0.18)' : 'transparent',
              color: active ? colors.text : colors.textMuted,
              fontSize: 13,
              transition: 'background 0.12s ease',
            }}
            onMouseEnter={(e) => {
              if (!active) (e.currentTarget as HTMLElement).style.background = colors.surface;
            }}
            onMouseLeave={(e) => {
              if (!active) (e.currentTarget as HTMLElement).style.background = 'transparent';
            }}
          >
            <span
              style={{
                width: 8,
                height: 8,
                borderRadius: 9999,
                background: l.color ?? colors.accent,
                flexShrink: 0,
              }}
            />
            <span style={{ flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{l.name}</span>
            {onDelete && l.id !== 'list-inbox' && (
              <button
                onClick={(e) => {
                  e.stopPropagation();
                  if (confirm(`删除列表"${l.name}"？该列表下的待办不会被删除。`)) onDelete(l.id);
                }}
                style={{
                  background: 'transparent',
                  border: 'none',
                  color: colors.textFaint,
                  fontSize: 12,
                  cursor: 'pointer',
                  padding: 2,
                }}
                title="删除列表"
              >
                ✕
              </button>
            )}
          </div>
        );
      })}

      {adding ? (
        <input
          autoFocus
          value={name}
          onChange={(e) => setName(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') commit();
            else if (e.key === 'Escape') {
              setName('');
              setAdding(false);
            }
          }}
          onBlur={commit}
          placeholder="新列表名"
          style={{
            padding: `6px ${spacing.sm}px`,
            fontSize: 13,
            background: colors.surfaceHigh,
            border: `1px solid ${colors.accent}`,
            borderRadius: radii.sm,
            color: colors.text,
            outline: 'none',
          }}
        />
      ) : (
        <button
          onClick={() => setAdding(true)}
          style={{
            background: 'transparent',
            border: `1px dashed ${colors.border}`,
            borderRadius: radii.sm,
            color: colors.textMuted,
            fontSize: 12,
            padding: `6px ${spacing.sm}px`,
            cursor: 'pointer',
            marginTop: 4,
          }}
        >
          + 新建列表
        </button>
      )}
    </div>
  );
}
