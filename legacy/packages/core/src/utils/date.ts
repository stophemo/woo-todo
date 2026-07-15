export function startOfDay(timestamp: number = Date.now()): number {
  const d = new Date(timestamp);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

export function endOfDay(timestamp: number = Date.now()): number {
  const d = new Date(timestamp);
  d.setHours(23, 59, 59, 999);
  return d.getTime();
}

export function isToday(timestamp?: number): boolean {
  if (!timestamp) return false;
  const t = startOfDay(timestamp);
  return t === startOfDay();
}

export function isOverdue(timestamp?: number): boolean {
  if (!timestamp) return false;
  return timestamp < Date.now();
}

/** 友好显示：今天 / 明天 / 后天 / YYYY-MM-DD */
export function formatDueDate(timestamp?: number): string | null {
  if (!timestamp) return null;
  const today = startOfDay();
  const target = startOfDay(timestamp);
  const diffDays = Math.round((target - today) / 86400000);
  if (diffDays === 0) return '今天';
  if (diffDays === 1) return '明天';
  if (diffDays === -1) return '昨天';
  if (diffDays === 2) return '后天';
  if (diffDays > 0 && diffDays < 7) return `${diffDays} 天后`;
  const d = new Date(timestamp);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}
