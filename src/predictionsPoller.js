/**
 * predictionsPoller.js
 *
 * Estratégia:
 *  1. A cada 1 hora: busca os fixtures do WC 2026 agendados nos próximos 7 dias
 *  2. Para cada fixture encontrado, busca as predictions
 *  3. Salva em memória e emite via Socket.IO
 *
 * O site nunca consulta a api-football diretamente — apenas recebe o cache.
 */

import { getPredictions, setPredictions } from './store.js'

const API_BASE  = 'https://v3.football.api-sports.io'
const LEAGUE_ID = 1      // FIFA World Cup
const SEASON    = 2026
const POLL_MS   = 60 * 60 * 1_000   // 1 hora
const DAYS_AHEAD = 14

function isoDate(date) {
  return date.toISOString().slice(0, 10)
}

async function apiFetch(path, apiKey) {
  const res = await fetch(`${API_BASE}${path}`, {
    headers: {
      'x-apisports-key': apiKey,
      'Accept': 'application/json',
    },
  })
  if (!res.ok) throw new Error(`api-football ${res.status}: ${res.statusText}`)
  return res.json()
}

async function poll(io, apiKey) {
  try {
    const today = isoDate(new Date())
    const in7   = isoDate(new Date(Date.now() + DAYS_AHEAD * 86_400_000))

    // 1. Fixtures agendados nos próximos 7 dias
    const fixturesData = await apiFetch(
      `/fixtures?league=${LEAGUE_ID}&season=${SEASON}&from=${today}&to=${in7}&status=NS`,
      apiKey
    )

    const fixtures = fixturesData.response ?? []
    if (fixtures.length === 0) {
      console.log('[predictions] nenhum fixture nos próximos 7 dias')
      return
    }

    console.log(`[predictions] buscando predictions para ${fixtures.length} fixtures…`)

    // 2. Predictions por fixture
    const predictions = getPredictions() ? { ...getPredictions() } : {}

    for (const fixture of fixtures) {
      const id = fixture.fixture.id
      try {
        const predData = await apiFetch(`/predictions?fixture=${id}`, apiKey)
        const pred     = predData.response?.[0]?.predictions
        if (!pred?.percent) continue

        predictions[id] = {
          fixtureId: id,
          homeTeam:  fixture.teams.home.name,
          awayTeam:  fixture.teams.away.name,
          home: parseInt(pred.percent.home)  || 0,
          draw: parseInt(pred.percent.draw)  || 0,
          away: parseInt(pred.percent.away)  || 0,
        }
      } catch (err) {
        console.warn(`[predictions] fixture ${id}: ${err.message}`)
      }
    }

    setPredictions(predictions)
    io.emit('predictions', predictions)
    console.log(`[predictions] cache atualizado — ${Object.keys(predictions).length} fixtures`)

  } catch (err) {
    console.error('[predictions] erro no poll:', err.message)
  }
}

export function startPredictionsPoller(io, apiKey) {
  if (!apiKey) {
    console.warn('[predictions] API_FOOTBALL_KEY não definida — predictions desativadas')
    return
  }

  poll(io, apiKey)
  setInterval(() => poll(io, apiKey), POLL_MS)
  console.log('[predictions] poller iniciado — intervalo 1h')
}
