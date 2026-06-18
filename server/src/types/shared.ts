/** 服务端与客户端共享的协议类型 */
export interface ServerTodo {
  id: string;
  data: string; // JSON-encoded Todo
  updated_at: number;
  deleted_at: number | null;
}

export interface ServerList {
  id: string;
  data: string;
  updated_at: number;
  deleted_at: number | null;
}
