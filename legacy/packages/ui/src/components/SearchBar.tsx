import { type ReactNode } from 'react';
import { colors, spacing, radii, type Style } from '../constants/theme.js';

export interface SearchBarProps {
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
  style?: Style;
}

export function SearchBar({ value, onChange, placeholder = '搜索…', style }: SearchBarProps): ReactNode {
  return (
    <div style={{ position: 'relative', ...style }}>
      <span
        style={{
          position: 'absolute',
          left: 10,
          top: '50%',
          transform: 'translateY(-50%)',
          color: colors.textMuted,
          fontSize: 12,
          pointerEvents: 'none',
        }}
      >
        🔍
      </span>
      <input
        value={value}
        onChange={(e) => onChange(e.target.value)}
        placeholder={placeholder}
        style={{
          width: '100%',
          padding: `${spacing.sm}px ${spacing.md}px ${spacing.sm}px 30px`,
          background: colors.surface,
          border: `1px solid ${colors.border}`,
          borderRadius: radii.md,
          color: colors.text,
          fontSize: 12,
          outline: 'none',
        }}
      />
      {value && (
        <button
          onClick={() => onChange('')}
          style={{
            position: 'absolute',
            right: 8,
            top: '50%',
            transform: 'translateY(-50%)',
            background: 'transparent',
            border: 'none',
            color: colors.textMuted,
            fontSize: 12,
            cursor: 'pointer',
            padding: 2,
          }}
          aria-label="清空搜索"
        >
          ✕
        </button>
      )}
    </div>
  );
}

/** 简单不区分大小写的子串匹配：content/tags/note 任意字段命中即返回 */
export function matchesSearch(haystack: { content: string; tags: string[]; note?: string }, needle: string): boolean {
  if (!needle) return true;
  const q = needle.toLowerCase();
  if (haystack.content.toLowerCase().includes(q)) return true;
  if (haystack.note?.toLowerCase().includes(q)) return true;
  return haystack.tags.some((t) => t.toLowerCase().includes(q));
}
