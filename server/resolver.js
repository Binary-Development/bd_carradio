const fs = require('fs')
const fsp = require('fs/promises')
const https = require('https')
const path = require('path')
const { spawn } = require('child_process')

const resourceName = GetCurrentResourceName()
const resourcePath = GetResourcePath(resourceName)
const toolsDir = path.join(resourcePath, 'data')

const settings = {
  binary: '',
  timeoutMs: 45000,
  maxParallelDownloads: 3,
  cookiesFile: '',
  proxy: '',
  cacheDir: path.join(resourcePath, 'data', 'cache'),
  maxBytes: 8 * 1024 * 1024 * 1024,
  ttlHours: 336,
  searchResults: 18,
  maxDurationSeconds: 900,
  autoUpdateHours: 12,
  playlistMaxTracks: 50,

  maxFileBytes: 104857600,
}

const mainThreadQueue = []

function onMainThread(fn) {
  mainThreadQueue.push(fn)
}

setTick(() => {
  if (mainThreadQueue.length === 0) return
  const batch = mainThreadQueue.splice(0, mainThreadQueue.length)
  for (const fn of batch) {
    try {
      fn()
    } catch (error) {
      console.log(`[binary-radio] ${error.message}`)
    }
  }
})

function log(message) {
  onMainThread(() => console.log(`[binary-radio] ${message}`))
}

function fromSelf() {
  const invoker = GetInvokingResource()
  return !invoker || invoker === resourceName
}

const windows = process.platform === 'win32'
const binaryName = windows ? 'yt-dlp.exe' : 'yt-dlp'
const releaseUrl = `https://github.com/yt-dlp/yt-dlp/releases/latest/download/${binaryName}`

function download(url, destination, redirects = 0) {
  return new Promise((resolve) => {
    if (redirects > 5) return resolve({ ok: false, error: 'too many redirects' })

    https
      .get(url, { headers: { 'user-agent': 'binary-radio' } }, (response) => {
        const status = response.statusCode || 0

        if (status >= 300 && status < 400 && response.headers.location) {
          response.resume()
          return resolve(download(response.headers.location, destination, redirects + 1))
        }

        if (status !== 200) {
          response.resume()
          return resolve({ ok: false, error: `download returned ${status}` })
        }

        const file = fs.createWriteStream(`${destination}.part`)
        response.pipe(file)
        file.on('finish', () => {
          file.close(() => {
            try {
              fs.renameSync(`${destination}.part`, destination)
              if (!windows) fs.chmodSync(destination, 0o755)
              resolve({ ok: true })
            } catch (error) {
              resolve({ ok: false, error: error.message })
            }
          })
        })
        file.on('error', (error) => resolve({ ok: false, error: error.message }))
      })
      .on('error', (error) => resolve({ ok: false, error: error.message }))
  })
}

function onPath(command) {
  return new Promise((resolve) => {
    let child
    try {
      child = spawn(command, ['--version'], { windowsHide: true })
    } catch {
      return resolve(false)
    }
    child.on('error', () => resolve(false))
    child.on('close', (code) => resolve(code === 0))
    setTimeout(() => {
      try {
        child.kill()
      } catch {
      }
      resolve(false)
    }, 10000)
  })
}

let ready = null

async function ensureBinary() {
  if (settings.binary) return settings.binary

  if (await onPath('yt-dlp')) {
    settings.binary = 'yt-dlp'
    log('using yt-dlp from PATH')
    return settings.binary
  }

  const local = path.join(toolsDir, binaryName)

  if (fs.existsSync(local)) {
    settings.binary = local
    return local
  }

  log('yt-dlp not found, downloading it once, this can take a minute')
  await fsp.mkdir(toolsDir, { recursive: true }).catch(() => {})

  const result = await download(releaseUrl, local)
  if (!result.ok) {
    log(`could not download yt-dlp: ${result.error}`)
    return ''
  }

  settings.binary = local
  log('yt-dlp downloaded')
  return local
}

function whenReady() {
  if (!ready) ready = ensureBinary()
  return ready
}

function runBinary(args, { timeoutMs = settings.timeoutMs, onLine } = {}) {
  return new Promise((resolve) => {
    if (!settings.binary) return resolve({ ok: false, error: 'yt-dlp is still installing' })

    let child
    try {
      child = spawn(settings.binary, args, { windowsHide: true })
    } catch (error) {
      return resolve({ ok: false, error: `spawn failed: ${error.message}` })
    }

    let stdout = ''
    let stderr = ''
    let settled = false

    const timer = setTimeout(() => {
      if (settled) return
      settled = true
      try {
        child.kill('SIGKILL')
      } catch {
      }
      resolve({ ok: false, error: 'timed out' })
    }, timeoutMs)

    let carry = ''

    child.stdout.on('data', (chunk) => {
      const text = chunk.toString('utf8')
      stdout += text
      if (!onLine) return

      carry += text
      const lines = carry.split('\n')
      carry = lines.pop() ?? ''

      for (const line of lines) {
        const trimmed = line.trim()
        if (trimmed) onLine(trimmed)
      }
    })
    child.stderr.on('data', (chunk) => {
      stderr += chunk.toString('utf8')
    })
    child.on('error', (error) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      resolve({ ok: false, error: error.code === 'ENOENT' ? 'yt-dlp not found' : error.message })
    })
    child.on('close', (code) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      if (code === 0) return resolve({ ok: true, stdout, stderr })
      const reason = stderr.trim().split('\n').filter(Boolean).pop() || `exit ${code}`
      resolve({ ok: false, error: reason })
    })
  })
}

async function updateBinary() {
  if (!settings.binary) return
  const result = await runBinary(['-U'], { timeoutMs: 180000 })
  if (result.ok) log(`yt-dlp: ${result.stdout.trim().split('\n').filter(Boolean).pop() || 'up to date'}`)
}

async function staleBinary() {
  if (settings.binary !== path.join(toolsDir, binaryName)) return false

  try {
    const stat = await fsp.stat(settings.binary)
    return Date.now() - stat.mtimeMs > settings.autoUpdateHours * 3600 * 1000
  } catch {
    return false
  }
}

function baseArgs(options = {}) {
  const args = ['--no-warnings', '--ignore-config', '--no-progress']
  if (!options.allowPlaylist) args.push('--no-playlist')
  if (settings.cookiesFile && fs.existsSync(settings.cookiesFile)) args.push('--cookies', settings.cookiesFile)
  if (settings.proxy) args.push('--proxy', settings.proxy)
  return args
}

const videoIdPattern = /^[A-Za-z0-9_-]{11}$/

function extractPlaylistId(input) {
  if (!input || typeof input !== 'string') return null
  const match = input.trim().match(/[?&]list=([A-Za-z0-9_-]+)/)
  return match ? match[1] : null
}

function playlistKind(listId) {
  if (!listId) return 'unknown'
  if (listId.startsWith('RD')) return 'mix'
  if (listId === 'WL') return 'watchlater'
  if (listId.startsWith('LM')) return 'likes'
  return 'playlist'
}

function isPlaylistUrl(input) {
  if (!input || typeof input !== 'string') return false
  const trimmed = input.trim()
  if (!extractPlaylistId(trimmed)) return false
  return trimmed.includes('/playlist') || /[?&]list=/.test(trimmed)
}

function canonicalPlaylistUrl(input, listId, kind) {
  if (kind === 'playlist') {
    return `https://www.youtube.com/playlist?list=${listId}`
  }

  const videoId = extractVideoId(input)
  if (videoId) {
    return `https://www.youtube.com/watch?v=${videoId}&list=${listId}`
  }

  return String(input).trim()
}

function entryVideoId(entry) {
  if (entry?.id && videoIdPattern.test(entry.id)) return entry.id

  const url = entry?.url || entry?.webpage_url || ''
  return extractVideoId(url)
}

function extractVideoId(input) {
  if (!input || typeof input !== 'string') return null
  const trimmed = input.trim()
  if (videoIdPattern.test(trimmed)) return trimmed

  const patterns = [
    /(?:youtube\.com|music\.youtube\.com)\/watch\?(?:.*&)?v=([A-Za-z0-9_-]{11})/,
    /youtu\.be\/([A-Za-z0-9_-]{11})/,
    /youtube\.com\/shorts\/([A-Za-z0-9_-]{11})/,
    /youtube\.com\/embed\/([A-Za-z0-9_-]{11})/,
    /youtube\.com\/live\/([A-Za-z0-9_-]{11})/,
  ]
  for (const pattern of patterns) {
    const match = trimmed.match(pattern)
    if (match) return match[1]
  }
  return null
}

function sourceFor(query) {
  const trimmed = String(query).trim()

  if (isPlaylistUrl(trimmed)) {
    const listId = extractPlaylistId(trimmed)
    const kind = playlistKind(listId)
    return {
      ok: true,
      kind: 'playlist',
      playlistKind: kind,
      id: listId,
      url: canonicalPlaylistUrl(trimmed, listId, kind),
    }
  }

  const videoId = extractVideoId(trimmed)
  if (!videoId) return { ok: false, error: 'that is not a YouTube link' }

  return { ok: true, kind: 'video', id: videoId, url: `https://www.youtube.com/watch?v=${videoId}` }
}

function playlistTracksFrom(parsed) {
  const entries = Array.isArray(parsed.entries) ? parsed.entries : []
  const tracks = []
  const seen = new Set()

  for (const entry of entries) {
    const id = entryVideoId(entry)
    if (!id || seen.has(id)) continue
    seen.add(id)

    const track = toTrack({ ...entry, id })
    if (!track.thumbnail) track.thumbnail = `https://i.ytimg.com/vi/${id}/hqdefault.jpg`
    if (track.duration > settings.maxDurationSeconds) continue

    tracks.push(track)
    if (track.duration > 0 && track.title !== 'Unknown') rememberMeta(track.id, track)
  }

  return tracks
}

async function loadPlaylist(source) {
  const limit = Math.max(1, Math.min(settings.playlistMaxTracks, 100))
  const kind = source.playlistKind || playlistKind(source.id)
  const url = source.url || canonicalPlaylistUrl('', source.id, kind)
  const result = await runBinary(
    [
      ...baseArgs({ allowPlaylist: true }),
      url,
      '--flat-playlist',
      '--dump-single-json',
      '--playlist-start',
      '1',
      '--playlist-end',
      String(limit),
    ],
    { timeoutMs: settings.timeoutMs * (kind === 'mix' ? 3 : 2) },
  )

  if (!result.ok) return { ok: false, error: result.error }

  let parsed
  try {
    parsed = JSON.parse(result.stdout)
  } catch {
    return { ok: false, error: 'could not read that playlist' }
  }

  const tracks = playlistTracksFrom(parsed)
  if (tracks.length === 0) return { ok: false, error: 'that playlist is empty' }

  const response = { ok: true, playlist: true, mix: kind === 'mix', tracks, track: tracks[0] }

  if (kind === 'mix') {
    response.notice =
      'that link is a YouTube mix, not a saved playlist. mixes are personalized per account, so without your YouTube cookies on the server the songs may not match what you see in the app'
  } else if (kind === 'watchlater' || kind === 'likes') {
    response.notice = 'library lists need your YouTube cookies on the server to match your account'
  }

  return response
}

const extensions = ['.m4a', '.mp4', '.webm', '.opus', '.ogg', '.mp3']

function pickThumbnail(entry) {
  if (entry.thumbnail) return entry.thumbnail
  const list = Array.isArray(entry.thumbnails) ? entry.thumbnails : []
  if (list.length === 0) return ''
  const sorted = [...list].sort((a, b) => (b.width || 0) - (a.width || 0))
  const medium = sorted.find((item) => (item.width || 0) <= 640) || sorted[sorted.length - 1]
  return medium.url || ''
}

function toTrack(entry) {
  return {
    id: entry.id || '',
    title: (entry.title || 'Unknown').slice(0, 140),
    author: (entry.channel || entry.uploader || entry.artist || 'Unknown').slice(0, 90),
    duration: Math.max(0, Math.floor(entry.duration || 0)),
    thumbnail: pickThumbnail(entry),
  }
}

async function search(query) {
  const limit = Math.max(1, Math.min(settings.searchResults, 30))
  const fetchLimit = Math.min(Math.max(limit * 3, 30), 50)
  const result = await runBinary([
    ...baseArgs(),
    `ytsearch${fetchLimit}:${query}`,
    '--flat-playlist',
    '--dump-single-json',
  ])
  if (!result.ok) return { ok: false, error: result.error }

  let parsed
  try {
    parsed = JSON.parse(result.stdout)
  } catch {
    return { ok: false, error: 'could not read the search results' }
  }

  const entries = Array.isArray(parsed.entries) ? parsed.entries : []
  const tracks = entries
    .filter((entry) => entry && entry.id)
    .map((entry) => {
      const track = toTrack(entry)
      if (!track.thumbnail) track.thumbnail = `https://i.ytimg.com/vi/${entry.id}/hqdefault.jpg`
      return track
    })
    .filter((track) => track.duration === 0 || track.duration <= settings.maxDurationSeconds)

  const ranked = rankTracks(query, tracks).slice(0, limit)
  const output = ranked.length > 0 ? ranked : tracks.slice(0, limit)

  if (output.length === 0) return { ok: false, error: 'no results found' }

  for (const track of output) {
    if (track.duration > 0 && track.title !== 'Unknown') rememberMeta(track.id, track)
  }

  return { ok: true, tracks: output }
}

const STOP_WORDS = new Set(['the', 'a', 'an', 'and', 'or', 'of', 'to', 'in', 'for', 'on', 'at', 'by'])
const PENALTIES = [
  'karaoke',
  'cover',
  'covers',
  'instrumental',
  'tutorial',
  'lesson',
  'how to',
  '8d audio',
  'bass boost',
  'nightcore',
  'sped up',
  'slowed',
  '1 hour',
  '10 hours',
  'full album',
  'lyrics video',
  'lyric video',
]

function tokenize(text) {
  return String(text || '')
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter((term) => term.length > 1 && !STOP_WORDS.has(term))
}

function rankTracks(query, tracks) {
  const terms = tokenize(query)
  const lowered = query.toLowerCase()

  return tracks
    .map((track) => {
      const title = (track.title || '').toLowerCase()
      const author = (track.author || '').toLowerCase()
      const blob = `${title} ${author}`
      let score = 0

      if (title === lowered) score += 30
      if (title.startsWith(lowered)) score += 14
      if (blob.includes(lowered)) score += 8

      for (const term of terms) {
        if (title.includes(term)) score += 6
        if (author.includes(term)) score += 3
        if (blob.includes(term)) score += 2
      }

      for (const bad of PENALTIES) {
        if (title.includes(bad)) score -= 5
      }

      if (track.duration > 0) {
        if (track.duration <= 420) score += 2
        if (track.duration > 1200) score -= 4
      }

      return { track, score }
    })
    .filter((entry) => entry.score > 0)
    .sort((a, b) => b.score - a.score)
    .map((entry) => entry.track)
}

const metaCacheLimit = 2000
const metaCache = new Map()
const metaWaiters = new Map()
const metaMarker = 'binaryradio-meta'
const metaFields = 'title,channel,uploader,artist,duration,thumbnail'
const metaWaitMs = 30000
let markerWorks = true

function rememberMeta(id, track) {
  if (metaCache.has(id)) metaCache.delete(id)
  metaCache.set(id, track)
  while (metaCache.size > metaCacheLimit) metaCache.delete(metaCache.keys().next().value)
}

async function acceptTrack(source, track) {
  track.id = source.id
  if (!track.thumbnail && videoIdPattern.test(source.id)) {
    track.thumbnail = `https://i.ytimg.com/vi/${source.id}/hqdefault.jpg`
  }

  if (track.duration <= 0) return { ok: false, error: 'could not read the track length' }
  if (track.duration > settings.maxDurationSeconds) {
    return { ok: false, error: `longer than ${Math.floor(settings.maxDurationSeconds / 60)} minutes` }
  }

  rememberMeta(source.id, track)
  await fsp.mkdir(settings.cacheDir, { recursive: true }).catch(() => {})
  await fsp.writeFile(path.join(settings.cacheDir, `${source.id}.json`), JSON.stringify(track)).catch(() => {})
  return { ok: true, track }
}

async function metadata(source) {
  if (source.kind !== 'video') return { ok: false, error: 'not a track' }

  if (metaCache.has(source.id)) return { ok: true, track: metaCache.get(source.id) }

  const metaPath = path.join(settings.cacheDir, `${source.id}.json`)
  try {
    const track = JSON.parse(await fsp.readFile(metaPath, 'utf8'))
    rememberMeta(source.id, track)
    return { ok: true, track }
  } catch {
  }

  const waiting = metaWaiters.get(source.id)
  if (waiting) {
    let timer
    const track = await Promise.race([
      waiting.promise,
      new Promise((resolve) => {
        timer = setTimeout(() => resolve(null), metaWaitMs)
      }),
    ])
    clearTimeout(timer)
    if (track) return acceptTrack(source, track)
  }

  const result = await runBinary([...baseArgs(), source.url, '--dump-single-json'])
  if (!result.ok) return { ok: false, error: result.error }

  let parsed
  try {
    parsed = JSON.parse(result.stdout)
  } catch {
    return { ok: false, error: 'could not read that track' }
  }

  if (parsed.is_live) return { ok: false, error: 'live streams are not supported' }

  return acceptTrack(source, toTrack(parsed))
}

const inFlight = new Map()
let activeDownloads = 0
const waiters = []

function acquireSlot() {
  if (activeDownloads < settings.maxParallelDownloads) {
    activeDownloads += 1
    return Promise.resolve()
  }
  return new Promise((resolve) => waiters.push(resolve))
}

function releaseSlot() {
  const next = waiters.shift()
  if (next) return next()
  activeDownloads = Math.max(0, activeDownloads - 1)
}

async function findCached(id) {
  for (const extension of extensions) {
    const candidate = path.join(settings.cacheDir, `${id}${extension}`)
    try {
      const stat = await fsp.stat(candidate)
      if (stat.size > 0) return candidate
    } catch {
    }
  }
  return null
}

function ensureAudio(source) {
  if (source.kind !== 'video') return Promise.resolve({ ok: false, error: 'not a track' })

  if (inFlight.has(source.id)) return inFlight.get(source.id)

  let settle = () => {}
  const pending = new Promise((resolve) => {
    settle = resolve
  })

  let settled = false
  let sawMarker = false

  const settleMeta = (track) => {
    if (settled) return
    settled = true
    metaWaiters.delete(source.id)
    settle(track)
  }

  if (markerWorks) metaWaiters.set(source.id, { promise: pending })

  const onLine = (line) => {
    if (!line.startsWith(metaMarker)) return
    sawMarker = true
    try {
      settleMeta(toTrack({ ...JSON.parse(line.slice(metaMarker.length + 1)), id: source.id }))
    } catch {
      settleMeta(null)
    }
  }

  const job = (async () => {
    try {
      const cached = await findCached(source.id)
      if (cached) return { ok: true, file: cached }

      await acquireSlot()

      try {
        await fsp.mkdir(settings.cacheDir, { recursive: true })
        const result = await runBinary(
          [
            ...baseArgs(),
            source.url,
            '-f',
            'bestaudio[ext=webm][abr<=96]/bestaudio[ext=webm]/bestaudio[abr<=96]/bestaudio',
            '-o',
            path.join(settings.cacheDir, `${source.id}.%(ext)s`),
            '--no-part',
            '--max-filesize',
            String(settings.maxFileBytes),
            '--match-filters',
            `duration < ${settings.maxDurationSeconds} & !is_live`,
            '-N',
            '4',
            '--print',
            `before_dl:${metaMarker} %(.{${metaFields}})j`,
            '--print',
            'after_move:filepath',
          ],
          { timeoutMs: settings.timeoutMs * 3, onLine },
        )

        if (!result.ok) return { ok: false, error: result.error }

        if (!sawMarker && markerWorks) {
          markerWorks = false
          log('yt-dlp did not print metadata during download, using a separate lookup from now on')
        }

        const printed = result.stdout
          .trim()
          .split('\n')
          .map((line) => line.trim())
          .filter((line) => line && !line.startsWith(metaMarker))
          .pop()

        const file = printed && fs.existsSync(printed) ? printed : await findCached(source.id)
        if (!file) return { ok: false, error: 'nothing was downloaded' }

        evictCache().catch(() => {})
        return { ok: true, file }
      } finally {
        releaseSlot()
      }
    } finally {
      settleMeta(null)
      inFlight.delete(source.id)
    }
  })()

  inFlight.set(source.id, job)
  return job
}

async function evictCache() {
  let names
  try {
    names = await fsp.readdir(settings.cacheDir)
  } catch {
    return
  }

  const stats = []
  let total = 0

  for (const name of names.filter((entry) => extensions.includes(path.extname(entry)))) {
    const full = path.join(settings.cacheDir, name)
    try {
      const stat = await fsp.stat(full)
      stats.push({ full, name, size: stat.size, atime: stat.atimeMs })
      total += stat.size
    } catch {
    }
  }

  const cutoff = Date.now() - settings.ttlHours * 3600 * 1000
  stats.sort((a, b) => a.atime - b.atime)

  for (const entry of stats) {
    if (entry.atime >= cutoff && total <= settings.maxBytes) break
    const id = path.basename(entry.name, path.extname(entry.name))
    if (inFlight.has(id)) continue
    try {
      await fsp.unlink(entry.full)
      total -= entry.size
      metaCache.delete(id)
      await fsp.unlink(path.join(settings.cacheDir, `${id}.json`)).catch(() => {})
    } catch {
    }
  }
}

on('binary-radio:internal:configure', (raw) => {
  if (!fromSelf()) return

  Object.assign(settings, typeof raw === 'string' ? JSON.parse(raw) : raw)
  if (!path.isAbsolute(settings.cacheDir)) settings.cacheDir = path.join(resourcePath, settings.cacheDir)
  fs.mkdirSync(settings.cacheDir, { recursive: true })

  whenReady().then(async () => {
    if (!settings.binary) return
    emit('binary-radio:internal:ready')
    if (settings.autoUpdateHours <= 0) return
    if (await staleBinary()) await updateBinary()
    setInterval(updateBinary, settings.autoUpdateHours * 3600 * 1000).unref?.()
  })

  evictCache().catch(() => {})
})

on('binary-radio:internal:search', (requestId, query) => {
  if (!fromSelf()) return

  whenReady()
    .then(() => search(String(query)))
    .then((result) => onMainThread(() => emit('binary-radio:internal:searched', requestId, JSON.stringify(result))))
})

on('binary-radio:internal:resolve', (requestId, query) => {
  if (!fromSelf()) return

  const answer = (result) =>
    onMainThread(() => emit('binary-radio:internal:resolved', requestId, JSON.stringify(result)))

  const source = sourceFor(String(query))
  if (!source.ok) return answer(source)

  if (source.kind === 'playlist') {
    whenReady()
      .then(() => loadPlaylist(source))
      .then((result) => {
        if (!result.ok || !Array.isArray(result.tracks)) return result

        const first = result.tracks[0]
        if (!first) return result

        void ensureAudio({ kind: 'video', id: first.id, url: `https://www.youtube.com/watch?v=${first.id}` })
        const upcoming = result.tracks[1]
        if (upcoming) {
          void ensureAudio({ kind: 'video', id: upcoming.id, url: `https://www.youtube.com/watch?v=${upcoming.id}` })
        }

        return result
      })
      .then(answer)
    return
  }

  whenReady()
    .then(async () => {
      ensureAudio(source)
        .then((audio) => {
          if (audio.ok) return
          log(`could not fetch ${source.id}: ${audio.error}`)
          onMainThread(() => emit('binary-radio:internal:unavailable', source.id))
        })
        .catch(() => onMainThread(() => emit('binary-radio:internal:unavailable', source.id)))

      const meta = await metadata(source)
      if (!meta.ok) return meta

      return { ok: true, track: meta.track }
    })
    .then(answer)
})

const mimes = {
  '.m4a': 'audio/mp4',
  '.mp4': 'audio/mp4',
  '.webm': 'audio/webm',
  '.opus': 'audio/ogg',
  '.ogg': 'audio/ogg',
  '.mp3': 'audio/mpeg',
}

on('binary-radio:internal:read', (requestId, id) => {
  if (!fromSelf()) return

  const answer = (mime, encoded) =>
    onMainThread(() => emit('binary-radio:internal:readAudio', requestId, mime, encoded))

  const source = sourceFor(String(id))
  if (!source.ok || source.kind !== 'video') return answer('', '')

  ensureAudio(source)
    .then(async (result) => {
      if (!result.ok) return answer('', '')

      const data = await fsp.readFile(result.file)
      answer(mimes[path.extname(result.file)] || 'audio/mpeg', data.toString('base64'))
    })
    .catch(() => answer('', ''))
})

on('binary-radio:internal:prefetch', (query) => {
  if (!fromSelf()) return

  const source = sourceFor(String(query))
  if (!source.ok || source.kind !== 'video') return

  whenReady().then(async () => {
    const meta = await metadata(source)
    if (meta.ok) void ensureAudio(source)
  })
})
