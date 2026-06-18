/** 跨端统一的设计 token */

export const darkColors = {
  bg: 'rgba(20, 20, 22, 0.75)',
  bgSolid: '#141416',
  surface: 'rgba(40, 40, 44, 0.6)',
  surfaceHigh: 'rgba(50, 50, 56, 0.85)',
  border: 'rgba(255, 255, 255, 0.08)',
  borderHigh: 'rgba(255, 255, 255, 0.16)',
  text: 'rgba(255, 255, 255, 0.95)',
  textMuted: 'rgba(255, 255, 255, 0.55)',
  textFaint: 'rgba(255, 255, 255, 0.35)',
  accent: '#818cf8',
  accentHigh: '#6366f1',
  success: 'rgba(100, 200, 130, 0.9)',
  danger: 'rgba(255, 100, 100, 0.9)',
  warning: 'rgba(255, 200, 100, 0.9)',
} as const;

export const lightColors = {
  bg: 'rgba(255, 255, 255, 0.78)',
  bgSolid: '#fafafa',
  surface: 'rgba(245, 245, 247, 0.7)',
  surfaceHigh: 'rgba(255, 255, 255, 0.95)',
  border: 'rgba(0, 0, 0, 0.08)',
  borderHigh: 'rgba(0, 0, 0, 0.16)',
  text: 'rgba(20, 20, 22, 0.95)',
  textMuted: 'rgba(20, 20, 22, 0.55)',
  textFaint: 'rgba(20, 20, 22, 0.35)',
  accent: '#6366f1',
  accentHigh: '#4f46e5',
  success: 'rgba(34, 160, 80, 0.9)',
  danger: 'rgba(220, 60, 60, 0.9)',
  warning: 'rgba(220, 150, 30, 0.9)',
} as const;

export const colors = darkColors; // 默认深色，兼容旧引用

export const priorityColors = {
  0: 'transparent',
  1: 'rgba(150, 200, 255, 0.7)',
  2: 'rgba(255, 200, 100, 0.8)',
  3: 'rgba(255, 100, 100, 0.85)',
} as const;

export const radii = {
  sm: 6,
  md: 10,
  lg: 14,
  xl: 18,
  full: 9999,
} as const;

export const spacing = {
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 24,
  xxl: 32,
} as const;

export const fonts = {
  body: 'system-ui, -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif',
  mono: 'ui-monospace, "SF Mono", Menlo, monospace',
} as const;
