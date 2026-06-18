import { useEffect, useState } from 'react';
import { windowApi, type WindowState } from './useWindowControl';

const INITIAL: WindowState = { alwaysOnTop: true, penetrate: false };

/**
 * 同步窗口状态（置顶/穿透）到 React state
 * Tauri 触发事件或托盘菜单改变窗口时自动更新
 */
export function useWindowState(): [WindowState, typeof windowApi] {
  const [state, setState] = useState<WindowState>(INITIAL);

  useEffect(() => {
    let unlisten: (() => void) | null = null;
    void (async () => {
      try {
        const initial = await windowApi.getState();
        setState({
          alwaysOnTop: initial.alwaysOnTop,
          penetrate: initial.penetrate,
        });
      } catch {
        // 非 Tauri 环境（普通浏览器预览）
      }
      unlisten = await windowApi.onStateChange(setState);
    })();
    return () => {
      unlisten?.();
    };
  }, []);

  return [state, windowApi];
}
