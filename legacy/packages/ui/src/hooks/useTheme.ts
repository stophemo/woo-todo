import { useEffect, useState } from 'react';
import { darkColors, lightColors, type ThemeMode } from '../constants/theme.js';

const STORAGE_KEY = 'woo-todo:theme-mode';

export type Theme = {
  mode: ThemeMode;
  isDark: boolean;
  colors: typeof darkColors;
};

const mql: MediaQueryList | null =
  typeof window !== 'undefined' && typeof window.matchMedia === 'function'
    ? window.matchMedia('(prefers-color-scheme: dark)')
    : null;

function resolveIsDark(mode: ThemeMode): boolean {
  if (mode === 'dark') return true;
  if (mode === 'light') return false;
  return mql?.matches ?? true;
}

export function useTheme(): [Theme, (mode: ThemeMode) => void] {
  const [mode, setMode] = useState<ThemeMode>(() => {
    if (typeof localStorage === 'undefined') return 'dark';
    return (localStorage.getItem(STORAGE_KEY) as ThemeMode | null) ?? 'dark';
  });
  const [isDark, setIsDark] = useState(() => resolveIsDark(mode));

  useEffect(() => {
    setIsDark(resolveIsDark(mode));
    if (mode !== 'system' || !mql) return;
    const handler = (e: MediaQueryListEvent) => setIsDark(e.matches);
    mql.addEventListener('change', handler);
    return () => mql.removeEventListener('change', handler);
  }, [mode]);

  function update(next: ThemeMode): void {
    setMode(next);
    try {
      localStorage.setItem(STORAGE_KEY, next);
    } catch {
      // 忽略
    }
  }

  return [
    {
      mode,
      isDark,
      colors: isDark ? darkColors : lightColors,
    },
    update,
  ];
}
