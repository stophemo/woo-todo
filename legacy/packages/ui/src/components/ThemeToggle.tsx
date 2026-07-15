import { type ReactNode } from 'react';
import { colors, spacing, radii, type Style } from '../constants/theme.js';

export type ThemeMode = 'dark' | 'light' | 'system';

export interface ThemeToggleProps {
  mode: ThemeMode;
  onChange: (mode: ThemeMode) => void;
  style?: Style;
}

const OPTIONS: { value: ThemeMode; icon: string; label: string }[] = [
  { value: 'dark', icon: '🌙', label: '深色' },
  { value: 'light', icon: '☀️', label: '亮色' },
  { value: 'system', icon: '🖥', label: '跟随系统' },
];

export function ThemeToggle({ mode, onChange, style }: ThemeToggleProps): ReactNode {
  return (
    <div
      style={{
        display: 'flex',
        gap: 4,
        padding: 2,
        background: colors.surface,
        borderRadius: radii.md,
        ...style,
      }}
    >
      {OPTIONS.map((o) => {
        const active = mode === o.value;
        return (
          <button
            key={o.value}
            onClick={() => onChange(o.value)}
            title={o.label}
            style={{
              flex: 1,
              padding: `${spacing.xs}px ${spacing.sm}px`,
              background: active ? 'rgba(129, 140, 248, 0.25)' : 'transparent',
              border: 'none',
              borderRadius: radii.sm,
              color: active ? colors.text : colors.textMuted,
              fontSize: 12,
              cursor: 'pointer',
            }}
          >
            {o.icon} {o.label}
          </button>
        );
      })}
    </div>
  );
}
