/**
 * 数据导出 - JSON / CSV
 * 桌面端：触发文件下载；移动端：返回字符串由宿主处理
 */

import type { Todo, TodoList } from '@woo-todo/core';

export function exportTodosAsJson(todos: Todo[], lists: TodoList[]): string {
  return JSON.stringify(
    {
      version: 2,
      exportedAt: new Date().toISOString(),
      todos: todos.filter((t) => !t.deletedAt),
      lists: lists.filter((l) => !l.deletedAt),
    },
    null,
    2
  );
}

export function exportTodosAsCsv(todos: Todo[]): string {
  const header = 'id,content,completed,listId,priority,tags,dueDate,note,createdAt,updatedAt\n';
  const rows = todos
    .filter((t) => !t.deletedAt)
    .map((t) => {
      const cells = [
        t.id,
        escapeCsv(t.content),
        t.completed ? 'true' : 'false',
        t.listId,
        String(t.priority),
        escapeCsv(t.tags.join('|')),
        t.dueDate ? new Date(t.dueDate).toISOString() : '',
        escapeCsv(t.note ?? ''),
        new Date(t.createdAt).toISOString(),
        new Date(t.updatedAt).toISOString(),
      ];
      return cells.join(',');
    });
  return header + rows.join('\n');
}

function escapeCsv(s: string): string {
  if (s.includes(',') || s.includes('"') || s.includes('\n')) {
    return `"${s.replace(/"/g, '""')}"`;
  }
  return s;
}

/** 浏览器端触发文件下载 */
export function downloadFile(filename: string, content: string, mimeType = 'application/json'): void {
  if (typeof document === 'undefined') return;
  const blob = new Blob([content], { type: mimeType });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}
