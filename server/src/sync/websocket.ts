import { WebSocketServer, WebSocket } from 'ws'
import type { Server } from 'http'

let wss: WebSocketServer
const clients = new Set<WebSocket>()

export function initWebSocket(server: Server) {
  wss = new WebSocketServer({ server, path: '/ws' })

  wss.on('connection', (ws) => {
    clients.add(ws)
    console.log(`[WS] client connected (total: ${clients.size})`)

    ws.on('close', () => {
      clients.delete(ws)
      console.log(`[WS] client disconnected (total: ${clients.size})`)
    })

    ws.on('message', (data) => {
      try {
        const msg = JSON.parse(data.toString())
        console.log('[WS] received:', msg.type)
      } catch {
        // ignore invalid messages
      }
    })

    // 发送欢迎消息
    ws.send(JSON.stringify({ type: 'connected', serverTime: Date.now() }))
  })
}

export function broadcast(message: object) {
  const data = JSON.stringify(message)
  for (const client of clients) {
    if (client.readyState === WebSocket.OPEN) {
      client.send(data)
    }
  }
}
