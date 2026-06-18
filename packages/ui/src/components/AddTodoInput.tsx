import { useState, type ReactNode, type KeyboardEvent } from 'react';
import { colors, spacing, radii, type Style } from '../constants/theme.js';
import type { Priority } from '@woo-todo/core';

export interface AddTodoInputProps {
  onAdd: (content: string, options?: { priority?: Priority; dueDate?: number }) => void;
  placeholder?: string;
  autoFocus?: boolean;
  style?: Style;
}

const PRIORITY_OPTIONS: { value: Priority; label: string; color: string }[] = [
  { value: 0, label: '无', color: 'rgba(255,255,255,0.25)' },
  { value: 1, label: '低', color: 'rgba(150, 200, 255, 0.8)' },
  { value: 2, label: '中', color: 'rgba(255, 200, 100, 0.9)' },
  { value: 3, label: '高', color: 'rgba(255, 100, 100, 0.95)' },
];

/** 紧凑日期输入：YYYY-MM-DD 格式，转换为时间戳 */
function parseDate(value: string): number | undefined {
  if (!value) return undefined;
  const t = new Date(value).getTime();
  return Number.isNaN(t) ? undefined : t;
}

export function AddTodoInput({ onAdd, placeholder = '新增待办，回车保存…', autoFocus, style }: AddTodoInputProps): ReactNode {
  const [value, setValue] = useState('');
  const [expanded, setExpanded] = useState(autoFocus ?? false);
  const [priority, setPriority] = useState<Priority>(0);
  const [dueDate, setDueDate] = useState('');

  function commit(): void {
    const v = value.trim();
    if (!v) {
      setExpanded(false);
      return;
    }
    onAdd(v, {
      priority: priority > 0 ? priority : undefined,
      dueDate: parseDate(dueDate),
    });
    setValue('');
    setPriority(0);
    setDueDate('');
  }

  function handleKey(e: KeyboardEvent<HTMLInputElement>): void {
    if (e.key === 'Enter') {
      e.preventDefault();
      commit();
    } else if (e.key === 'Escape') {
      setValue('');
      setPriority(0);
      setDueDate('');
      setExpanded(false);
    }
  }

  if (!expanded) {
    return (
      <button
        onClick={() => setExpanded(true)}
        style={{
          width: '100%',
          padding: spacing.md,
          background: 'transparent',
          border: `1px dashed ${colors.border}`,
          borderRadius: radii.md,
          color: colors.textMuted,
          fontSize: 13,
          cursor: 'pointer',
          transition: 'all 0.15s ease',
          ...style,
        }}
      >
        + {placeholder}
      </button>
    );
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 6, ...style }}>
      <input
        autoFocus
        value={value}
        onChange={(e) => setValue(e.target.value)}
        onKeyDown={handleKey}
        onBlur={() => {
          // 失焦时不立即收起，等用户点其他控件
        }}
        placeholder={placeholder}
        style={{
          width: '100%',
          padding: spacing.md,
          background: colors.surfaceHigh,
          border: `1px solid ${colors.accent}`,
          borderRadius: radii.md,
          color: colors.text,
          fontSize: 13,
          outline: 'none',
        }}
      />
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
        <div style={{ display: 'flex', gap: 4 }}>
          {PRIORITY_OPTIONS.map((p) => (
            <button
              key={p.value}
              type="button"
              onClick={() => setPriority(p.value)}
              title={`优先级：${p.label}`}
              style={{
                padding: '3px 8px',
                fontSize: 11,
                background: priority === p.value ? `${p.color}30` : 'transparent',
                border: `1px solid ${priority === p.value ? p.color : colors.border}`,
                borderRadius: radii.sm,
                color: priority === p.value ? p.color : colors.textMuted,
                cursor: 'pointer',
              }}
            >
              {p.label}
            </button>
          ))}
        </div>
        <input
          type="date"
          value={dueDate}
          onChange={(e) => setDueDate(e.target.value)}
          style={{
            padding: '3px 6px',
            fontSize: 11,
            background: colors.surfaceHigh,
            border: `1px solid ${colors.border}`,
            borderRadius: radii.sm,
            color: colors.text,
            colorScheme: 'dark',
            outline: 'none',
          }}
        />
        {dueDate && (
          <button
            type="button"
            onClick={() => setDueDate('')}
            style={{ background: 'none', border: 'none', color: colors.textMuted, fontSize: 11, cursor: 'pointer' }}
          >
            ✕
          </button>
        )}
      </div>
    </div>
  );
}
