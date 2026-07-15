import type { ReactNode } from 'react';
import { colors, spacing, radii } from '@woo-todo/ui';

export interface TitleBarProps {
  title: string;
  alwaysOnTop: boolean;
  penetrate: boolean;
  onToggleTop: () => void;
  onTogglePenetrate: () => void;
  onOpenSettings?: () => void;
}

export function TitleBar({
  title,
  alwaysOnTop,
  penetrate,
  onToggleTop,
  onTogglePenetrate,
  onOpenSettings,
}: TitleBarProps): ReactNode {
  return (
    <div
      data-tauri-drag-region
      style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        padding: `${spacing.sm}px ${spacing.md}px`,
        borderBottom: `1px solid ${colors.border}`,
        cursor: 'grab',
      }}
    >
      <span style={{ fontSize: 12, fontWeight: 600, letterSpacing: 0.4, color: colors.textMuted }}>{title}</span>
      <div style={{ display: 'flex', gap: 4 }}>
        {onOpenSettings && (
          <IconButton active={false} onClick={onOpenSettings} label="设置" icon="⚙" />
        )}
        <IconButton
          active={alwaysOnTop}
          onClick={onToggleTop}
          label={alwaysOnTop ? '取消置顶' : '置顶'}
          icon="📌"
        />
        <IconButton
          active={penetrate}
          onClick={onTogglePenetrate}
          label={penetrate ? '退出穿透' : '穿透模式'}
          icon="👻"
        />
      </div>
    </div>
  );
}

function IconButton({
  active,
  onClick,
  icon,
  label,
}: {
  active: boolean;
  onClick: () => void;
  icon: string;
  label: string;
}): ReactNode {
  return (
    <button
      onClick={onClick}
      title={label}
      aria-label={label}
      style={{
        width: 26,
        height: 26,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        background: active ? 'rgba(129, 140, 248, 0.25)' : 'transparent',
        border: 'none',
        borderRadius: radii.sm,
        fontSize: 13,
        cursor: 'pointer',
        opacity: active ? 1 : 0.55,
        transition: 'all 0.15s ease',
      }}
      onMouseEnter={(e) => {
        (e.currentTarget as HTMLElement).style.opacity = '1';
      }}
      onMouseLeave={(e) => {
        (e.currentTarget as HTMLElement).style.opacity = active ? '1' : '0.55';
      }}
    >
      {icon}
    </button>
  );
}
