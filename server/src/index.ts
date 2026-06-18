import { createServer } from 'node:http';
import { WebSocketServer } from 'ws';
import { createApp } from './app.js';
import { attachWebSocket } from './sync/websocket.js';

const PORT = Number(process.env.PORT ?? 3001);

const app = createApp();
const server = createServer(app);
const wss = new WebSocketServer({ server, path: '/ws' });
attachWebSocket(wss);

server.listen(PORT, () => {
  console.log(`[woo-todo-server] listening on http://localhost:${PORT}`);
  console.log(`[woo-todo-server] websocket on ws://localhost:${PORT}/ws`);
});
