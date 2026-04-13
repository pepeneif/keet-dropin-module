Here is the complete **`install_keet_dropin.sh`** script ready to be placed in the directory you specified (`/home/pepeneif/.nanobot/workspace/sessions`).  
Copy the content below and save it as `install_keet_dropin.sh` (be sure the file is executable: `chmod +x install_keet_dropin.sh`).

```bash
#!/usr/bin/env bash
# =============================================================================
# install_keet_dropin.sh
# =============================================================================
#   - Detects automatically if the agent is Nanobot, CoPaw (QwenPaw),
#     Hermes‑agent or OpenClaw.
#   - Installs Node v20 (if missing) inside the workspace.
#   - Installs the NPM dependencies required by Keet.
#   - Creates the three Keet skills (create‑room, join‑room, send‑message)
#     with optional room‑name argument and auto‑generated sessionId.
#   - Always creates the persistent folder ~/.nanobot/rooms.
#   - Generates the appropriate channel plug‑ins:
#       * CoPaw → custom_channels/keet_channel.py  (registered via copaw)
#       * Hermes‑agent → ~/.hermes/plugins/keet_plugin.py
#       * OpenClaw → src/plugins/keet-channel/keet-channel.ts
#   - Makes the scripts executable and prints a short usage guide.
# =============================================================================

set -euo pipefail

# -------------------------------------------------------------------------
# Helper functions for pretty output
# -------------------------------------------------------------------------
log()   { printf "\e[32m[✔]\e[0m %s\n" "$*"; }
warn()  { printf "\e[33m[!]\e[0m %s\n" "$*"; }
error() { printf "\e[31m[✖]\e[0m %s\n" "$*" >&2; exit 1; }

# -------------------------------------------------------------------------
# 1️⃣ Detect which OpenClaw‑family agent is running
# -------------------------------------------------------------------------
AGENT_TYPE="unknown"
if command -v nanobot >/dev/null 2>&1; then AGENT_TYPE="nanobot"; fi
if command -v copaw   >/dev/null 2>&1; then AGENT_TYPE="copaw";   fi
if command -v hermes-agent >/dev/null 2>&1; then AGENT_TYPE="hermes"; fi
if [[ -d "$(pwd)/src" && -f "$(pwd)/package.json" ]]; then AGENT_TYPE="openclaw"; fi

if [[ "$AGENT_TYPE" == "unknown" ]]; then
  error "No se encontró ningún binario de agente (nanobot / copaw / hermes-agent) ni un workspace de OpenClaw. Abortando."
fi
log "Agente detectado: $AGENT_TYPE"

# -------------------------------------------------------------------------
# 2️⃣ Define workspace paths based on the detected agent
# -------------------------------------------------------------------------
case "$AGENT_TYPE" in
  nanobot) WORKSPACE="${HOME}/.nanobot/workspace"; SKILLS_ROOT="${WORKSPACE}/skills";;
  copaw)   WORKSPACE="${HOME}/.copaw";           SKILLS_ROOT="${WORKSPACE}/skills"; CHANNEL_ROOT="${WORKSPACE}/custom_channels";;
  hermes)  WORKSPACE="${HOME}/.hermes";          SKILLS_ROOT="${WORKSPACE}/skills"; PLUGIN_ROOT="${HOME}/.hermes/plugins";;
  openclaw)WORKSPACE="$(pwd)";                 SKILLS_ROOT="${WORKSPACE}/skills"; PLUGIN_ROOT="${WORKSPACE}/src/plugins/keet-channel";;
esac
mkdir -p "$WORKSPACE"
log "Workspace → $WORKSPACE"

# -------------------------------------------------------------------------
# 3️⃣ Ensure Node v20 is present (download it if necessary)
# -------------------------------------------------------------------------
NODE_DIR="${WORKSPACE}/node-v20.12.0-linux-x64"
NODE_BIN="${NODE_DIR}/bin/node"
NPM_BIN="${NODE_DIR}/bin/npm"

if [[ -x "$NODE_BIN" ]]; then
  log "Node v20 already present → $NODE_BIN"
else
  log "Downloading Node v20.12.0..."
  TMPDIR=$(mktemp -d)
  pushd "$TMPDIR" >/dev/null
  NODE_TAR="node-v20.12.0-linux-x64.tar.xz"
  NODE_URL="https://nodejs.org/dist/v20.12.0/${NODE_TAR}"
  curl -fsSLO "$NODE_URL"
  tar -xJf "$NODE_TAR" -C "$WORKSPACE" --strip-components=1
  popd >/dev/null
  rm -rf "$TMPDIR"
  log "Node installed in $WORKSPACE"
fi
export PATH="${NODE_DIR}/bin:$PATH"

# -------------------------------------------------------------------------
# 4️⃣ Init a Node project (if missing) and install required npm packages
# -------------------------------------------------------------------------
cd "$WORKSPACE"
if [[ ! -f "package.json" ]]; then
  log "Initializing a new Node project..."
  npm init -y > /dev/null
fi
log "Installing required npm dependencies..."
npm install blind-pairing-core hypercore-id-encoding hypercore random-access-memory random-access-file > /dev/null 2>&1
log "Dependencies installed"

# -------------------------------------------------------------------------
# 5️⃣ Always create the persistent rooms folder (~/.nanobot/rooms)
# -------------------------------------------------------------------------
ROOMS_DIR="${HOME}/.nanobot/rooms"
mkdir -p "$ROOMS_DIR"
log "Persistent rooms folder → $ROOMS_DIR"

# -------------------------------------------------------------------------
# 6️⃣ Generate the three Keet skills (common to all agents)
# -------------------------------------------------------------------------
mkdir -p "${SKILLS_ROOT}/keet-create-room"
mkdir -p "${SKILLS_ROOT}/keet-join-room"
mkdir -p "${SKILLS_ROOT}/keet-send-message"

# ---- keet-create-room -------------------------------------------------
cat > "${SKILLS_ROOT}/keet-create-room/SKILL.md" <<'EOF'
---
name: keet-create-room
description: Crea una sala (room) en keet.io y devuelve la URL de invitación.
---
EOF

cat > "${SKILLS_ROOT}/keet-create-room/create_room.js" <<'EOF'
#!/home/pepeneif/.nanobot/workspace/node-v20.12.0-linux-x64/bin/node
/**
 * keet-create-room – genera una nueva sala Keet.
 * Uso: keet-create-room [<nombre-de-sala>]
 * Si no se indica nombre, se genera un UUID usado como nombre y como sessionId.
 */
const { createInvite } = require('blind-pairing-core')
const { encode }      = require('hypercore-id-encoding')
const crypto          = require('crypto')

// 1️⃣  Obtener nombre opcional y generar sessionId
let roomName = process.argv.slice(2).join(' ').trim()
const sessionId = crypto.randomUUID()
if (!roomName) roomName = sessionId

// 2️⃣  Generar clave y discoveryKey
const key = crypto.randomBytes(32)
const { discoveryKey } = createInvite(key)

// 3️⃣  Identificador codificado en z‑base‑32 (52 caracteres)
const identifier = encode(discoveryKey)

// 4️⃣  Formar la URL oficial de Keet
const inviteUrl = `pear://keet/${identifier}`

// 5️⃣  Salida JSON
console.log(JSON.stringify({
  roomId: identifier,
  inviteUrl,
  sessionId,
  roomName
}))
EOF
chmod +x "${SKILLS_ROOT}/keet-create-room/create_room.js"
log "Skill keet-create-room generated"

# ---- keet-join-room ---------------------------------------------------
cat > "${SKILLS_ROOT}/keet-join-room/SKILL.md" <<'EOF'
---
name: keet-join-room
description: Entra a una sala Keet a partir de su URL pear://keet/... y permite leer y enviar mensajes.
---
EOF

cat > "${SKILLS_ROOT}/keet-join-room/join_room.js" <<'EOF'
#!/home/pepeneif/.nanobot/workspace/node-v20.12.0-linux-x64/bin/node
/**
 * keet-join-room – se une a una sala Keet mediante su invite URL.
 * Uso: keet-join-room <pear://keet/...> [--session <session-id>]
 * Historial persistente en ~/.nanobot/rooms/<roomId>_<sessionId>.dat
 */
const { decode } = require('hypercore-id-encoding')
const hypercore  = require('hypercore')
const RAF        = require('random-access-file')
const readline   = require('readline')
const crypto     = require('crypto')
const path       = require('path')
const os         = require('os')
const fs         = require('fs')

// ---------- 1️⃣ argumentos ----------
const args = process.argv.slice(2)
if (args.length < 1) {
  console.error('Usage: keet-join-room <pear://keet/...> [--session <session-id>]')
  process.exit(1)
}
const url = args[0]

// ---------- 2️⃣ manejar flag --session ----------
let sessionId = null
for (let i = 1; i < args.length; i++) {
  if (args[i] === '--session' && i + 1 < args.length) {
    sessionId = args[i + 1]
    break
  }
}
if (!sessionId) sessionId = crypto.randomUUID()

// ---------- 3️⃣ validar URL ----------
const m = url.match(/^pear:\/\/keet\/([^/]+)$/)
if (!m) {
  console.error('Invalid Keet invite URL')
  process.exit(1)
}
const identifier = m[1]

// ---------- 4️⃣ decodificar ----------
let discoveryKey
try { discoveryKey = decode(identifier) }
catch (e) {
  console.error('Decode error:', e.message)
  process.exit(1)
}

// ---------- 5️⃣ ruta del almacenamiento ----------
const roomsBase = path.join(os.homedir(), '.nanobot', 'rooms')
if (!fs.existsSync(roomsBase)) fs.mkdirSync(roomsBase, { recursive: true })
const storagePath = path.join(roomsBase, `${identifier}_${sessionId}.dat`)

// ---------- 6️⃣ abrir hypercore ----------
const core = hypercore(RAF, discoveryKey, { valueEncoding: 'utf-8' })

core.on('ready', () => {
  console.log(`Joined Keet room ${identifier}`)
  console.log(`(session: ${sessionId})`)

  // Lectura en vivo + historial previo
  const rs = core.createReadStream({ live: true })
  rs.on('data', data => console.log(`[peer] ${data}`))
})

// ---------- 7️⃣ envío desde stdin ----------
const rl = readline.createInterface({ input: process.stdin, output: process.stdout })
rl.on('line', line => {
  core.append(line, err => {
    if (err) console.error('Append error:', err)
    else console.log(`[you] ${line}`)
  })
})
EOF
chmod +x "${SKILLS_ROOT}/keet-join-room/join_room.js"
log "Skill keet-join-room generated"

# ---- keet-send-message -------------------------------------------------
cat > "${SKILLS_ROOT}/keet-send-message/SKILL.md" <<'EOF'
---
name: keet-send-message
description: Envía un mensaje único a una sala Keet usando su URL pear://keet/.
---
EOF

cat > "${SKILLS_ROOT}/keet-send-message/send_message.js" <<'EOF'
#!/home/pepeneif/.nanobot/workspace/node-v20.12.0-linux-x64/bin/node
/**
 * keet-send-message – envía un solo mensaje a una sala Keet.
 * Uso: keet-send-message <pear://keet/...> <msg> [--session <session-id>]
 */
const { decode } = require('hypercore-id-encoding')
const hypercore  = require('hypercore')
const RAF        = require('random-access-file')
const path       = require('path')
const os         = require('os')
const fs         = require('fs')
const crypto     = require('crypto')

// ---------- 1️⃣ argumentos ----------
const raw = process.argv.slice(2)
if (raw.length < 2) {
  console.error('Usage: keet-send-message <pear://keet/...> <msg> [--session <session-id>]')
  process.exit(1)
}
const url = raw[0]

// parse message while respecting optional flag
let msgParts = [], sessionId = null
for (let i = 1; i < raw.length; i++) {
  if (raw[i] === '--session' && i + 1 < raw.length) {
    sessionId = raw[i + 1]; i++; continue
  }
  msgParts.push(raw[i])
}
const message = msgParts.join(' ')
if (!sessionId) sessionId = crypto.randomUUID()

// ---------- 2️⃣ validar URL ----------
const m = url.match(/^pear:\/\/keet\/([^/]+)$/)
if (!m) {
  console.error('Invalid Keet invite URL')
  process.exit(1)
}
const identifier = m[1]

// ---------- 3️⃣ decodificar ----------
let discoveryKey
try { discoveryKey = decode(identifier) }
catch (e) {
  console.error('Decode error:', e.message)
  process.exit(1)
}

// ---------- 4️⃣ ruta de almacenamiento ----------
const roomsBase = path.join(os.homedir(), '.nanobot', 'rooms')
if (!fs.existsSync(roomsBase)) fs.mkdirSync(roomsBase, { recursive: true })
const storagePath = path.join(roomsBase, `${identifier}_${sessionId}.dat`)

// ---------- 5️⃣ abrir hypercore y enviar ----------
const core = hypercore(RAF, discoveryKey, { valueEncoding: 'utf-8' })
core.append(message, err => {
  if (err) console.error('Append error:', err)
  else console.log('Message sent')
})
EOF
chmod +x "${SKILLS_ROOT}/keet-send-message/send_message.js"
log "Skill keet-send-message generated"

# -------------------------------------------------------------------------
# 7️⃣ Create channel plug‑ins for the other platforms (if relevant)
# -------------------------------------------------------------------------

# ---- CoPaw (custom_channels) -------------------------------------------
if [[ "$AGENT_TYPE" == "copaw" ]]; then
  mkdir -p "${CHANNEL_ROOT}"
  cat > "${CHANNEL_ROOT}/keet_channel.py" <<'EOF'
"""
CoPaw (QwenPaw) Channel – “Keet”

Provides three sub‑commands that simply call the Node scripts generated
by the installer.
"""

import subprocess
from copaw.channels.base import BaseChannel   # type: ignore

class KeetChannel(BaseChannel):
    name = "keet"
    description = "Keet P2P chat (hypercore) channel"

    def _run(self, script: str, *args):
        cmd = [
            "/home/pepeneif/.nanobot/workspace/node-v20.12.0-linux-x64/bin/node",
            f"/home/pepenefi/.nanobot/workspace/skills/{script}",
            *args
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return result.stdout.strip()

    async def create(self, ctx):
        out = self._run("keet-create-room/create_room.js")
        await ctx.send(out)

    async def join(self, ctx, url: str, *flags):
        args = [url, *flags]
        proc = subprocess.Popen(
            [
                "/home/pepeneif/.nanobot/workspace/node-v20.12.0-linux-x64/bin/node",
                "/home/pepeneif/.nanobot/workspace/skills/keet-join-room/join_room.js",
                *args
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        for line in proc.stdout:
            await ctx.send(line.rstrip())

    async def send(self, ctx, url: str, *msg_and_flags):
        out = self._run("keet-send-message/send_message.js", url, *msg_and_flags)
        await ctx.send(out)

# Automatic registration
channel = KeetChannel()
EOF
  # Register the channel in CoPaw
  copaw channels add keet >/dev/null 2>&1 || true
  log "CoPaw channel ‘keet’ added"
fi

# ---- Hermes‑agent (Python plugin) ----------------------------------------
if [[ "$AGENT_TYPE" == "hermes" ]]; then
  mkdir -p "${PLUGIN_ROOT}"
  cat > "${PLUGIN_ROOT}/keet_plugin.py" <<'EOF'
"""
Hermes‑agent plug‑in for Keet.

Exports three functions that the Hermes runtime can call:

* keet_create(room_name=None)
* keet_join(url, session_id=None)
* keet_send(url, message, session_id=None)
"""

import subprocess
import os

NODE_BIN = "/home/pepeneif/.nanobot/workspace/node-v20.12.0-linux-x64/bin/node"
SKILLS_ROOT = "/home/pepeneif/.nanobot/workspace/skills"

def _run(script_path: str, *args) -> str:
    cmd = [NODE_BIN, script_path, *args]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    return result.stdout.strip()

def keet_create(room_name: str = None) -> dict:
    args = [room_name] if room_name else []
    out = _run(os.path.join(SKILLS_ROOT, "keet-create-room", "create_room.js"), *args)
    return eval(out)   # JSON string → Python dict

def keet_join(url: str, session_id: str = None) -> None:
    args = [url]
    if session_id:
        args += ["--session", session_id]
    proc = subprocess.Popen(
        [NODE_BIN, os.path.join(SKILLS_ROOT, "keet-join-room", "join_room.js"), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    for line in proc.stdout:
        print(line.rstrip())   # Hermes captures stdout

def keet_send(url: str, message: str, session_id: str = None) -> str:
    args = [url, message]
    if session_id:
        args += ["--session", session_id]
    out = _run(os.path.join(SKILLS_ROOT, "keet-send-message", "send_message.js"), *args)
    return out
EOF
  log "Hermes‑agent plug‑in written to ${PLUGIN_ROOT}/keet_plugin.py"
fi

# ---- OpenClaw (TypeScript plug‑in) --------------------------------------
if [[ "$AGENT_TYPE" == "openclaw" ]]; then
  mkdir -p "${PLUGIN_ROOT}"
  cat > "${PLUGIN_ROOT}/keet-channel.ts" <<'EOF'
import { createChatChannelPlugin } from "openclaw/plugin-sdk/channel-core";
import { spawn } from "child_process";
import path from "path";

/**
 * OpenClaw channel plug‑in that forwards everything to the Node scripts
 * produced by the Keet drop‑in installer.
 *
 * The plug‑in implements three commands:
 *   - createRoom(name?)
 *   - joinRoom(url, sessionId?)
 *   - sendMessage(url, message, sessionId?)
 *
 * All commands invoke the same Node scripts that Nanobot/CoPaw/Hermes use,
 * ensuring identical behaviour across the ecosystem.
 */
export const keetChannel = createChatChannelPlugin
