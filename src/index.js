import 'dotenv/config'
import express      from 'express'
import { createServer } from 'http'
import { Server }   from 'socket.io'
import { getCache, getPredictions } from './store.js'
import { startPoller } from './poller.js'
import { startPredictionsPoller } from './predictionsPoller.js'

const PORT               = process.env.PORT || 3001
const ALLOWED_ORIGIN     = process.env.ALLOWED_ORIGIN || 'http://localhost:5174'
const FOOTBALL_DATA_KEY  = process.env.FOOTBALL_DATA_API_KEY
const API_FOOTBALL_KEY   = process.env.API_FOOTBALL_KEY   // opcional

if (!FOOTBALL_DATA_KEY) {
  console.error('[server] FOOTBALL_DATA_API_KEY não definida — abortando.')
  process.exit(1)
}

// ── HTTP + Socket.IO ─────────────────────────────────────────────────────────
const app        = express()
const httpServer = createServer(app)
const io         = new Server(httpServer, {
  cors: { origin: ALLOWED_ORIGIN, methods: ['GET'] },
})

// ── REST (debug) ──────────────────────────────────────────────────────────────
app.get('/health', (_req, res) => {
  res.json({ status: 'ok', ts: Date.now(), clients: io.engine.clientsCount })
})

app.get('/snapshot', (_req, res) => {
  res.json(getCache() ?? {})
})

app.get('/predictions', (_req, res) => {
  res.json(getPredictions() ?? {})
})

// ── Socket.IO ─────────────────────────────────────────────────────────────────
io.on('connection', (socket) => {
  console.log(`[socket] conectado: ${socket.id}  (total: ${io.engine.clientsCount})`)

  // Envia caches atuais imediatamente para o novo cliente
  const cached = getCache()
  if (cached) socket.emit('matches', cached)

  const preds = getPredictions()
  if (preds) socket.emit('predictions', preds)

  socket.on('ping', () => socket.emit('pong'))

  socket.on('disconnect', () => {
    console.log(`[socket] desconectado: ${socket.id}  (total: ${io.engine.clientsCount - 1})`)
  })
})

// ── Pollers ───────────────────────────────────────────────────────────────────
startPoller(io, FOOTBALL_DATA_KEY)
startPredictionsPoller(io, API_FOOTBALL_KEY)

// ── Sobe o servidor ───────────────────────────────────────────────────────────
httpServer.listen(PORT, '0.0.0.0', () => {
  console.log(`[server] http://0.0.0.0:${PORT}  origem: ${ALLOWED_ORIGIN}`)
})
