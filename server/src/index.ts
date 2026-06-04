import express from 'express'
import cors from 'cors'
import http from 'http'
import todosRouter from './routes/todos'
import { initWebSocket } from './sync/websocket'

const app = express()
const PORT = process.env.PORT || 3001

app.use(cors())
app.use(express.json())

// REST API
app.use('/api/todos', todosRouter)

// 健康检查
app.get('/health', (_req, res) => {
  res.json({ status: 'ok', time: Date.now() })
})

const server = http.createServer(app)
initWebSocket(server)

server.listen(PORT, () => {
  console.log(`[woo-todo-server] running on http://localhost:${PORT}`)
  console.log(`[woo-todo-server] WebSocket at ws://localhost:${PORT}/ws`)
})
