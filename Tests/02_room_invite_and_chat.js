#!/usr/bin/env node
'use strict'

const crypto = require('crypto')
const fs = require('fs')
const path = require('path')
const readline = require('readline')
const Hyperswarm = require('hyperswarm')
const { createInvite, decodeInvite } = require('blind-pairing-core')
const { encode: encodeCoreKey, decode: decodeCoreKey } = require('hypercore-id-encoding')
const z32 = require('z32')

const INVITE_FORMAT_DISCOVERY = 'discovery-key'
const INVITE_FORMAT_CANONICAL = 'canonical-invite'

const DEFAULT_INVITE_PORT = 49737
const DEFAULT_INVITE_TTL_MS = 7 * 24 * 60 * 60 * 1000
const DEFAULT_INVITE_NODES = [
  { host: '1.1.1.1', port: DEFAULT_INVITE_PORT },
  { host: '8.8.8.8', port: DEFAULT_INVITE_PORT },
  { host: '9.9.9.9', port: DEFAULT_INVITE_PORT },
  { host: '8.8.4.4', port: DEFAULT_INVITE_PORT },
  { host: '208.67.222.222', port: DEFAULT_INVITE_PORT },
  { host: '208.67.220.220', port: DEFAULT_INVITE_PORT },
  { host: '94.140.14.14', port: DEFAULT_INVITE_PORT }
]

function printHelp() {
  console.log(`Keet Test 02 - Create room + inviteURL + interactive keep-alive chat

Usage:
  # Create room and stay online (recommended for host)
  node ./Tests/02_room_invite_and_chat.js --name HostUser

  # Create room, print metadata, and exit
  node ./Tests/02_room_invite_and_chat.js --create-only

  # Create room with experimental long canonical invite URL
  node ./Tests/02_room_invite_and_chat.js --create-only --invite-format canonical

  # Join an existing room by invite URL and keep chat open
  node ./Tests/02_room_invite_and_chat.js --invite pear://keet/<roomId> --name GuestUser

Options:
  --name <text>          Display name in chat (default: random peer id)
  --invite <url>         Existing room invite URL (pear://keet/<roomId>)
  --key <hex|base64>     32-byte key for deterministic room creation (only when creating)
  --invite-format <fmt>  Invite generation format: discovery (default) | canonical (experimental)
  --create-only          Only create/validate room + invite URL and exit
  --save <file>          Save room metadata to JSON file
  --no-stdin             Keep connection/watch loop but disable local keyboard input
  --help                 Show this help

Notes:
  - Default generation uses Keet-client-compatible discovery-key roomIds.
  - Experimental long canonical blind-pairing invite format is opt-in via --invite-format canonical.
  - Parsing accepts both formats so you can still join either type.
  - It keeps a room topic open while running and allows message exchange with other participants
    running this same script in the same invite URL.
`)
}

function normalizeInviteFormat(raw) {
  const value = String(raw || '').trim().toLowerCase()
  if (!value || value === 'discovery' || value === 'discovery-key' || value === 'compat' || value === 'client') {
    return INVITE_FORMAT_DISCOVERY
  }
  if (value === 'canonical' || value === 'canonical-invite' || value === 'long') {
    return INVITE_FORMAT_CANONICAL
  }
  throw new Error('Invalid --invite-format value. Expected discovery or canonical.')
}

function parseArgs(argv) {
  const cfg = {
    name: null,
    invite: null,
    key: null,
    inviteFormat: INVITE_FORMAT_DISCOVERY,
    createOnly: false,
    save: null,
    stdin: true,
    help: false
  }

  for (let i = 0; i < argv.length; i++) {
    const token = argv[i]
    if (token === '--name' && i + 1 < argv.length) {
      cfg.name = argv[++i]
      continue
    }
    if (token === '--invite' && i + 1 < argv.length) {
      cfg.invite = argv[++i]
      continue
    }
    if (token === '--key' && i + 1 < argv.length) {
      cfg.key = argv[++i]
      continue
    }
    if (token === '--invite-format' && i + 1 < argv.length) {
      cfg.inviteFormat = normalizeInviteFormat(argv[++i])
      continue
    }
    if (token === '--create-only') {
      cfg.createOnly = true
      continue
    }
    if (token === '--save' && i + 1 < argv.length) {
      cfg.save = argv[++i]
      continue
    }
    if (token === '--no-stdin') {
      cfg.stdin = false
      continue
    }
    if (token === '--help' || token === '-h') {
      cfg.help = true
      continue
    }
    throw new Error('Unknown argument: ' + token)
  }

  return cfg
}

function parseKey(raw) {
  const value = String(raw || '').trim()
  if (!value) throw new Error('Missing key value')
  if (/^[0-9a-fA-F]{64}$/.test(value)) return Buffer.from(value, 'hex')

  const buf = Buffer.from(value, 'base64')
  if (buf.byteLength === 32) return buf
  throw new Error('Invalid --key value. Expected 32-byte hex (64 chars) or base64.')
}

function parseInviteUrl(url) {
  const m = String(url || '').trim().match(/^pear:\/\/keet\/([^/\s]+)$/)
  if (!m) throw new Error('Invalid invite URL. Expected pear://keet/<roomId>')
  const roomId = m[1]

  // Legacy mode (discovery key encoded directly as 52-char z32 / 64-char hex)
  try {
    const legacyDiscoveryKey = decodeCoreKey(roomId)
    if (legacyDiscoveryKey && legacyDiscoveryKey.byteLength === 32) {
      return {
        roomId,
        inviteUrl: `pear://keet/${roomId}`,
        discoveryKey: Buffer.from(legacyDiscoveryKey),
        inviteFormat: INVITE_FORMAT_DISCOVERY,
        invitePayload: null
      }
    }
  } catch (_) {}

  // Canonical mode (z32-encoded blind-pairing invite payload)
  let invitePayload
  try {
    invitePayload = z32.decode(roomId)
  } catch (_) {
    throw new Error('Invalid roomId payload in invite URL')
  }

  let decoded
  try {
    decoded = decodeInvite(invitePayload)
  } catch (_) {
    throw new Error('Invalid roomId payload in invite URL')
  }

  if (!decoded.discoveryKey || decoded.discoveryKey.byteLength !== 32) {
    throw new Error('Invalid roomId payload in invite URL')
  }

  return {
    roomId,
    inviteUrl: `pear://keet/${roomId}`,
    discoveryKey: Buffer.from(decoded.discoveryKey),
    inviteFormat: INVITE_FORMAT_CANONICAL,
    invitePayload
  }
}

function createRoomFromKey(keyBuf, inviteFormat = INVITE_FORMAT_DISCOVERY) {
  const { invite } = createInvite(keyBuf, {
    expires: Date.now() + DEFAULT_INVITE_TTL_MS,
    additionalNodes: DEFAULT_INVITE_NODES
  })
  const decoded = decodeInvite(invite)
  if (!decoded.discoveryKey || decoded.discoveryKey.byteLength !== 32) {
    throw new Error('createInvite/decodeInvite failed: invalid discovery key')
  }
  const roomId = inviteFormat === INVITE_FORMAT_CANONICAL
    ? z32.encode(invite)
    : encodeCoreKey(decoded.discoveryKey)
  const inviteUrl = `pear://keet/${roomId}`

  const parsed = parseInviteUrl(inviteUrl)
  if (!parsed.discoveryKey.equals(Buffer.from(decoded.discoveryKey))) {
    throw new Error('Room validation failed: discovery key mismatch after URL decode')
  }
  if (parsed.inviteFormat !== inviteFormat) {
    throw new Error('Room validation failed: invite format mismatch after URL decode')
  }

  let discoveryRoomIdRoundtripOk = null
  if (inviteFormat === INVITE_FORMAT_DISCOVERY) {
    const roundtrip = decodeCoreKey(roomId)
    discoveryRoomIdRoundtripOk = Buffer.from(roundtrip).equals(Buffer.from(decoded.discoveryKey))
    if (!discoveryRoomIdRoundtripOk) {
      throw new Error('Room validation failed: discovery-key roomId roundtrip mismatch')
    }
  }

  return {
    roomId,
    inviteUrl,
    discoveryKey: Buffer.from(decoded.discoveryKey),
    inviteFormat,
    inviteUrlLength: inviteUrl.length,
    keetClientCompatible: inviteFormat === INVITE_FORMAT_DISCOVERY,
    discoveryRoomIdRoundtripOk,
    ownerKeyHex: keyBuf.toString('hex'),
    ownerKeyBase64: keyBuf.toString('base64')
  }
}

function saveJson(target, payload) {
  const outPath = path.resolve(target)
  fs.mkdirSync(path.dirname(outPath), { recursive: true })
  fs.writeFileSync(outPath, JSON.stringify(payload, null, 2) + '\n', { mode: 0o600 })
  fs.chmodSync(outPath, 0o600)
  console.error('[saved] ' + outPath)
}

function encodeMessage(msg) {
  return Buffer.from(JSON.stringify(msg) + '\n', 'utf-8')
}

function randomPeerId() {
  return crypto.randomBytes(4).toString('hex')
}

async function runInteractiveChat({ roomId, inviteUrl, discoveryKey, displayName, noStdin }) {
  const MAX_SOCKET_BUFFER_BYTES = 1024 * 1024
  const peerId = randomPeerId()
  const swarm = new Hyperswarm()
  const peers = new Set()
  const seen = new Set()

  function broadcast(obj) {
    const payload = encodeMessage(obj)
    for (const socket of peers) {
      if (!socket.destroyed) socket.write(payload)
    }
  }

  function logLine(line) {
    process.stdout.write(line + '\n')
  }

  function onIncomingLine(line) {
    if (!line) return
    let msg
    try {
      msg = JSON.parse(line)
    } catch (_) {
      return
    }

    if (!msg || typeof msg !== 'object') return
    if (typeof msg.id === 'string') {
      if (seen.has(msg.id)) return
      seen.add(msg.id)
      if (seen.size > 10000) {
        const first = seen.values().next()
        if (!first.done) seen.delete(first.value)
      }
    }

    if (msg.type === 'chat') {
      const from = String(msg.from || 'peer')
      const text = String(msg.text || '')
      logLine(`[${from}] ${text}`)
      return
    }

    if (msg.type === 'join') {
      logLine(`[system] ${String(msg.from || 'peer')} joined`)
      return
    }

    if (msg.type === 'leave') {
      logLine(`[system] ${String(msg.from || 'peer')} left`)
    }
  }

  function wireSocket(socket) {
    peers.add(socket)
    socket.setEncoding('utf-8')

    let buffer = ''
    let bufferBytes = 0
    socket.on('data', (chunk) => {
      buffer += chunk
      bufferBytes += Buffer.byteLength(chunk, 'utf-8')
      if (bufferBytes > MAX_SOCKET_BUFFER_BYTES) {
        peers.delete(socket)
        socket.destroy()
        return
      }

      while (true) {
        const idx = buffer.indexOf('\n')
        if (idx < 0) break
        const line = buffer.slice(0, idx).trim()
        buffer = buffer.slice(idx + 1)
        bufferBytes = Buffer.byteLength(buffer, 'utf-8')
        onIncomingLine(line)
      }
    })

    socket.on('close', () => peers.delete(socket))
    socket.on('error', () => peers.delete(socket))
  }

  swarm.on('connection', (socket) => {
    wireSocket(socket)
  })

  const discovery = swarm.join(discoveryKey, { client: true, server: true })
  await discovery.flushed()

  logLine('Room is active. Keep this process running to keep presence in the room.')
  logLine('inviteUrl: ' + inviteUrl)
  logLine('roomId: ' + roomId)
  logLine('peerId: ' + peerId)
  logLine('name: ' + displayName)
  logLine('connected peers: ' + peers.size)
  logLine('Type messages and press Enter to send. Ctrl+C to exit.')

  broadcast({
    id: crypto.randomUUID(),
    type: 'join',
    from: `${displayName}#${peerId}`,
    ts: new Date().toISOString()
  })

  let rl = null
  if (!noStdin) {
    rl = readline.createInterface({ input: process.stdin, output: process.stdout })
    rl.on('line', (line) => {
      const text = String(line || '').trim()
      if (!text) return
      const evt = {
        id: crypto.randomUUID(),
        type: 'chat',
        from: `${displayName}#${peerId}`,
        text,
        ts: new Date().toISOString()
      }
      seen.add(evt.id)
      broadcast(evt)
      logLine(`[you] ${text}`)
    })
  }

  let shuttingDown = false
  async function shutdown() {
    if (shuttingDown) return
    shuttingDown = true

    broadcast({
      id: crypto.randomUUID(),
      type: 'leave',
      from: `${displayName}#${peerId}`,
      ts: new Date().toISOString()
    })

    if (rl) rl.close()
    try { await swarm.destroy() } catch (_) {}
    process.exit(0)
  }

  process.on('SIGINT', shutdown)
  process.on('SIGTERM', shutdown)
}

async function main() {
  const cfg = parseArgs(process.argv.slice(2))
  if (cfg.help) {
    printHelp()
    return
  }

  const displayName = String(cfg.name || '').trim() || 'participant'

  let room
  if (cfg.invite) {
    const parsed = parseInviteUrl(cfg.invite)
    room = {
      roomId: parsed.roomId,
      inviteUrl: parsed.inviteUrl,
      discoveryKey: parsed.discoveryKey,
      inviteFormat: parsed.inviteFormat,
      keetClientCompatible: parsed.inviteFormat === INVITE_FORMAT_DISCOVERY,
      discoveryRoomIdRoundtripOk: parsed.inviteFormat === INVITE_FORMAT_DISCOVERY
        ? Buffer.from(decodeCoreKey(parsed.roomId)).equals(parsed.discoveryKey)
        : null,
      ownerKeyHex: null,
      ownerKeyBase64: null
    }
  } else {
    const key = cfg.key ? parseKey(cfg.key) : crypto.randomBytes(32)
    room = createRoomFromKey(key, cfg.inviteFormat)
  }

  const summary = {
    ok: true,
    roomId: room.roomId,
    inviteUrl: room.inviteUrl,
    inviteFormat: room.inviteFormat || INVITE_FORMAT_DISCOVERY,
    inviteUrlLength: room.inviteUrl.length,
    keetClientCompatible: room.keetClientCompatible,
    discoveryRoomIdRoundtripOk: room.discoveryRoomIdRoundtripOk,
    discoveryKeyHex: room.discoveryKey.toString('hex'),
    ownerKeyHex: room.ownerKeyHex,
    ownerKeyBase64: room.ownerKeyBase64,
    mode: cfg.invite ? 'join-existing-room' : 'create-room'
  }

  console.log(JSON.stringify(summary, null, 2))
  if (cfg.save) saveJson(cfg.save, summary)
  if (cfg.createOnly) return

  await runInteractiveChat({
    roomId: room.roomId,
    inviteUrl: room.inviteUrl,
    discoveryKey: room.discoveryKey,
    displayName,
    noStdin: !cfg.stdin
  })
}

main().catch((err) => {
  console.error(err && err.message ? err.message : String(err))
  process.exit(1)
})
