/**
 * Poller — consulta a football-data.org exatamente 10 vezes/minuto (a cada 6s).
 * Faz broadcast via Socket.IO apenas quando os dados mudarem.
 */

import {
  getCache, setCache,
  getLastEtag, setLastEtag,
  getLastFingerprint, setLastFingerprint,
} from './store.js'

const API_BASE    = 'https://api.football-data.org/v4'
const COMPETITION = 'WC'
const POLL_MS     = 6_000   // 10 req/min

function fingerprint(data) {
  if (!data?.matches) return ''
  return data.matches
    .filter(m => m.status === 'FINISHED')
    .map(m => `${m.id}:${m.score?.fullTime?.home}-${m.score?.fullTime?.away}`)
    .join('|')
}

async function poll(io, apiKey) {
  const headers = {
    'X-Auth-Token': apiKey,
    Accept: 'application/json',
  }

  const etag = getLastEtag()
  if (etag) headers['If-None-Match'] = etag

  let res
  try {
    res = await fetch(`${API_BASE}/competitions/${COMPETITION}/matches`, { headers })
  } catch (err) {
    console.error('[poller] fetch error:', err.message)
    io.emit('error', { message: String(err) })
    return
  }

  // 304 Not Modified — nada mudou
  if (res.status === 304) {
    console.log(`[poller] 304 Not Modified — ${new Date().toISOString()}`)
    return
  }

  if (!res.ok) {
    console.error(`[poller] upstream error ${res.status}: ${res.statusText}`)
    io.emit('error', { status: res.status, message: res.statusText })
    return
  }

  const newEtag = res.headers.get('ETag')
  if (newEtag) setLastEtag(newEtag)

  const data = await res.json()

  // Fingerprint evita broadcast de dados idênticos quando ETag não está disponível
  const fp = fingerprint(data)
  if (fp === getLastFingerprint() && getCache() !== null) {
    console.log(`[poller] fingerprint unchanged — ${new Date().toISOString()}`)
    return
  }
  setLastFingerprint(fp)
  setCache(data)

  io.emit('matches', data)
  console.log(`[poller] broadcast — ${new Date().toISOString()} — ${data.matches?.length ?? 0} jogos`)
}

export function startPoller(io, apiKey) {
  // Primeira consulta imediata ao iniciar
  poll(io, apiKey)

  // Mantém exatamente 10 req/min com setInterval fixo
  setInterval(() => poll(io, apiKey), POLL_MS)

  console.log(`[poller] iniciado — intervalo ${POLL_MS}ms (10 req/min)`)
}
