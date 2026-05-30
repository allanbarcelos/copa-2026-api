/**
 * Store em memória — compartilhado entre pollers e servidor HTTP/Socket.IO.
 */

// ── football-data.org ────────────────────────────────────────────────────────
let cache           = null
let lastEtag        = null
let lastFingerprint = null

export const getCache           = ()  => cache
export const setCache           = (v) => { cache = v }
export const getLastEtag        = ()  => lastEtag
export const setLastEtag        = (v) => { lastEtag = v }
export const getLastFingerprint = ()  => lastFingerprint
export const setLastFingerprint = (v) => { lastFingerprint = v }

// ── api-football (predictions) ───────────────────────────────────────────────
let predictionsCache = null  // { [fixtureId]: { homeTeam, awayTeam, home, draw, away } }

export const getPredictions = ()  => predictionsCache
export const setPredictions = (v) => { predictionsCache = v }
