import { type CSSProperties, type ReactNode } from 'react';

export type Style = CSSProperties & Record<string, unknown>;

/**
 * Checkbox - 跨端共享的勾选框
 * 桌面用 div + onClick；移动端 RN 也支持 div/View 抽象
 */

export interface CheckboxProps {
  checked: boolean;
  onChange: (checked: boolean) => void;
  size?: number;
  disabled?: boolean;
  style?: Style;
}

const S: Record<string, Style> = {
  base: {
    display: 'inline-flex',
    alignItems: 'center',
    justifyContent: 'center',
    border: '1.5px solid rgba(255, 255, 255, 0.5)',
    borderRadius: 9999,
    background: 'transparent',
    transition: 'all 0.18s ease',
    cursor: 'pointer',
    userSelect: 'none',
  },
  checked: {
    background: 'rgba(100, 200, 130, 0.9)',
    borderColor: 'rgba(100, 200, 130, 1)',
  },
  check: {
    color: 'white',
    fontWeight: 700,
    fontSize: '0.85em',
    lineHeight: 1,
  },
};

export function Checkbox({ checked, onChange, size = 20, disabled, style }: CheckboxProps): ReactNode {
  return (
    <div
      role="checkbox"
      aria-checked={checked}
      onClick={(e) => {
        if (disabled) return;
        e.stopPropagation();
        onChange(!checked);
      }}
      style={{
        ...S.base,
        width: size,
        height: size,
        ...(checked ? S.checked : {}),
        opacity: disabled ? 0.4 : 1,
        cursor: disabled ? 'not-allowed' : 'pointer',
        ...style,
      }}
    >
      {checked ? <span style={S.check}>✓</span> : null}
    </div>
  );
}
