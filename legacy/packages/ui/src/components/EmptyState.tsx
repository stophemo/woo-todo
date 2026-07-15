import { type ReactNode } from 'react';
import { colors, spacing } from '../constants/theme.js';

export function EmptyState({ title = '没有待办', hint = '享受片刻宁静' }: { title?: string; hint?: string }): ReactNode {
  return (
    <div
      style={{
        textAlign: 'center',
        padding: `${spacing.xxl}px ${spacing.lg}px`,
        color: colors.textMuted,
      }}
    >
      <div style={{ fontSize: 32, marginBottom: spacing.sm, opacity: 0.4 }}>✓</div>
      <div style={{ fontSize: 13, marginBottom: 4 }}>{title}</div>
      <div style={{ fontSize: 11, opacity: 0.7 }}>{hint}</div>
    </div>
  );
}
