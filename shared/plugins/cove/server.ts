#!/usr/bin/env bun
// server.ts — Cove channel plugin for Claude Code
//
// Decision C: fs.watch-based inbox reader. No relay connection from this process.
// Daemon (anya-cove-daemon.ts) stays as independent systemd process and writes
// received messages to INBOX_DIR via pushSessionNotification().
//
// This server watches INBOX_DIR for new JSON files, parses the pre-wrapped
// <channel> tag, and injects them as MCP channel notifications.
//
// Tools: cove_send (daemon socket), cove_recv (direct inbox read),
//        cove_list / cove_my_pubkey / cove_pending_invites (SQLite/cert),
//        cove_accept / cove_reject (file-drop command), cove_rehello (socket+fallback)

import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import { ListToolsRequestSchema, CallToolRequestSchema } from '@modelcontextprotocol/sdk/types.js'
import { watch, existsSync, mkdirSync } from 'node:fs'
import { readFile, rename, stat, readdir, writeFile, mkdir } from 'node:fs/promises'
import { join } from 'node:path'
import { homedir } from 'node:os'
import { createConnection } from 'node:net'
import { randomUUID } from 'node:crypto'
import { Database } from 'bun:sqlite'

// ---- Config ----------------------------------------------------------------

const HOME = process.env.HOME ?? homedir()
const COVE_STATE_DIR = process.env.COVE_STATE_DIR ?? join(HOME, '.claude-bots', 'state', 'anya')
const INBOX_DIR = join(COVE_STATE_DIR, 'inbox', 'messages')
const SOCK_PATH = process.env.COVE_SOCK ?? join(HOME, '.claude-bots', 'bots', 'anya', 'services', 'cove', 'cove-send.sock')
const DB_PATH = process.env.COVE_DB ?? join(HOME, '.claude-bots', 'bots', 'anya', 'services', 'cove', 'invites.db')
const CERT_PATH = process.env.COVE_CERT ?? join(HOME, '.cove', 'agents', 'anya', 'cert.json')
const COMMANDS_DIR = process.env.COVE_COMMANDS_DIR ?? join(HOME, '.claude-bots', 'bots', 'anya', 'inbox', 'cove-commands')

const REPLAY_CAP = 200
const DAEMON_TIMEOUT_MS = 5_000
const POLL_INTERVAL_MS = 5_000

// ---- Logging ---------------------------------------------------------------

function log(...args: unknown[]): void {
  process.stderr.write(
    '[cove-plugin] ' + args.map(a => typeof a === 'string' ? a : JSON.stringify(a)).join(' ') + '\n',
  )
}

// ---- XML helpers -----------------------------------------------------------

export function xmlEscape(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;')
}

export function xmlUnescape(s: string): string {
  return s
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&')  // must be last — &amp; → & would corrupt other entities if done first
}

export interface ChannelTagAttrs {
  chat_id: string
  message_id: string
  user: string
  ts: string
  plaintext: string
}

/**
 * Parse a pre-wrapped <channel> tag written by pushSessionNotification().
 * Returns null if content is NOT a <channel> tag (fall back to raw-text path).
 *
 * pushSessionNotification writes:
 *   content = '<channel source="plugin:cove" chat_id="PUBKEY" message_id="ENVID" user="HANDLE" ts="ISO">XML_ESCAPED_TEXT</channel>'
 *
 * Claude Code channel plugin expects raw plaintext as content + structured meta.
 * This function extracts both to avoid double-wrapping.
 */
export function parseChannelTag(content: string): ChannelTagAttrs | null {
  const m = content.match(/^<channel([^>]*)>([\s\S]*)<\/channel>$/)
  if (!m) return null
  const attrsStr = m[1]!
  const inner = m[2]!

  function attr(name: string): string {
    const re = new RegExp(`${name}="([^"]*)"`)
    return re.exec(attrsStr)?.[1] ?? ''
  }

  return {
    chat_id: attr('chat_id'),
    message_id: attr('message_id'),
    user: attr('user'),
    ts: attr('ts'),
    plaintext: xmlUnescape(inner),
  }
}

// ---- In-memory dedup set ---------------------------------------------------

const deliveredIds = new Set<string>()

async function loadDeliveredIds(): Promise<void> {
  try {
    const files = await readdir(INBOX_DIR)
    for (const f of files.filter(f => f.endsWith('.delivered'))) {
      try {
        const raw = await readFile(join(INBOX_DIR, f), 'utf8')
        const parsed = JSON.parse(raw) as { params?: { meta?: { envelope_id?: string } } }
        const eid = parsed.params?.meta?.envelope_id
        if (eid) deliveredIds.add(eid)
      } catch {}
    }
  } catch {}
}

// ---- Daemon socket proxy ---------------------------------------------------

export interface DaemonResponse {
  ok: boolean
  data?: unknown
  error?: string
}

export async function daemonOp(
  payload: Record<string, unknown>,
  timeoutMs = DAEMON_TIMEOUT_MS,
): Promise<DaemonResponse> {
  return new Promise((resolve) => {
    let settled = false
    const finish = (r: DaemonResponse) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      try { conn.destroy() } catch {}
      resolve(r)
    }

    if (!existsSync(SOCK_PATH)) {
      return resolve({ ok: false, error: 'DAEMON_DOWN' })
    }

    const timer = setTimeout(() => finish({ ok: false, error: 'DAEMON_DOWN' }), timeoutMs)
    const conn = createConnection(SOCK_PATH)
    let buf = ''

    conn.on('error', () => finish({ ok: false, error: 'DAEMON_DOWN' }))
    conn.on('connect', () => { conn.write(JSON.stringify(payload) + '\n') })
    conn.on('data', (chunk) => {
      buf += chunk.toString('utf8')
      const nl = buf.indexOf('\n')
      if (nl === -1) return
      const line = buf.slice(0, nl).trim()
      try {
        finish(JSON.parse(line) as DaemonResponse)
      } catch {
        finish({ ok: false, error: `bad daemon response: ${line.slice(0, 100)}` })
      }
    })
  })
}

// ---- MCP server instance (set in main) ------------------------------------

let mcp!: Server

// ---- Notification delivery -------------------------------------------------

async function sendChannelNotification(attrs: ChannelTagAttrs): Promise<void> {
  // Content is raw plaintext — Claude Code wraps it in <channel source="plugin:cove" ...>.
  // meta fields map directly to <channel> tag attributes.
  await mcp.notification({
    method: 'notifications/claude/channel',
    params: {
      content: attrs.plaintext,
      meta: {
        chat_id: attrs.chat_id,
        recipient: attrs.chat_id,
        message_id: attrs.message_id,
        user: attrs.user,
        user_id: attrs.chat_id,
        ts: attrs.ts,
        source: 'cove',
      },
    },
  })
}

// ---- Single-file processing (fs.watch trigger) ----------------------------

async function processFile(filePath: string, filename: string): Promise<void> {
  if (filename.endsWith('.delivered') || filename.endsWith('.delivering') || filename.endsWith('.tmp')) return

  const deliveringPath = filePath + '.delivering'
  const deliveredPath = filePath + '.delivered'

  // Two-phase rename: mark as delivering before sending (crash safety)
  try {
    await rename(filePath, deliveringPath)
  } catch {
    return // already renamed by concurrent processInboxDir
  }

  try {
    const raw = await readFile(deliveringPath, 'utf8')
    const parsed = JSON.parse(raw) as {
      params?: { content?: string; meta?: { envelope_id?: string } }
    }
    const content = (parsed.params?.content ?? '').trim()
    const envId = parsed.params?.meta?.envelope_id

    if (envId && deliveredIds.has(envId)) {
      await rename(deliveringPath, deliveredPath)
      return
    }

    const attrs = parseChannelTag(content)
    if (!attrs) {
      log(`WARN: unparseable channel tag in ${filename}, skipping`)
      await rename(deliveringPath, deliveredPath)
      return
    }

    await sendChannelNotification(attrs)
    if (envId) deliveredIds.add(envId)
    await rename(deliveringPath, deliveredPath)
    log(`DELIVERED ${filename} from=${attrs.user} env=${attrs.message_id.slice(0, 8)}`)
  } catch (err) {
    log(`ERROR processing ${filename}: ${err}`)
    try { await rename(deliveringPath, filePath) } catch {}
  }
}

// ---- Batch directory scan (5s fallback poll + startup replay) --------------

async function processInboxDir(isReplay = false): Promise<void> {
  try {
    const files = await readdir(INBOX_DIR)

    // Crash recovery: re-deliver any .delivering files from a previous run
    for (const f of files.filter(f => f.endsWith('.delivering'))) {
      const fp = join(INBOX_DIR, f)
      const deliveredPath = fp.replace('.delivering', '.delivered')
      try {
        const raw = await readFile(fp, 'utf8')
        const parsed = JSON.parse(raw) as { params?: { content?: string; meta?: { envelope_id?: string } } }
        const envId = parsed.params?.meta?.envelope_id
        if (envId && deliveredIds.has(envId)) { await rename(fp, deliveredPath); continue }
        const attrs = parseChannelTag(parsed.params?.content ?? '')
        if (attrs) {
          await sendChannelNotification(attrs)
          if (envId) deliveredIds.add(envId)
        }
        await rename(fp, deliveredPath)
        log(`RECOVERY ${f}`)
      } catch (err) { log(`RECOVERY ERROR ${f}: ${err}`) }
    }

    // Pending .json files (not .tmp, .delivering, .delivered)
    const pending = files.filter(f =>
      f.endsWith('.json') && !f.endsWith('.tmp'),
    )

    // Sort by filename (starts with ms timestamp) = chronological order
    // Also get mtime as tiebreaker
    const withMtime = await Promise.all(
      pending.map(async (f) => {
        try {
          const s = await stat(join(INBOX_DIR, f))
          return { name: f, mtime: s.mtimeMs }
        } catch {
          return { name: f, mtime: 0 }
        }
      }),
    )
    withMtime.sort((a, b) => {
      const tsDiff = a.name.localeCompare(b.name)
      return tsDiff !== 0 ? tsDiff : a.mtime - b.mtime
    })

    const capped = withMtime.slice(0, REPLAY_CAP)
    if (isReplay && withMtime.length > REPLAY_CAP) {
      log(`WARN: ${withMtime.length} pending files to replay, capped at ${REPLAY_CAP}`)
    }

    for (const { name } of capped) {
      await processFile(join(INBOX_DIR, name), name)
    }
  } catch {}
}

// ---- Startup replay --------------------------------------------------------

async function replayInbox(): Promise<void> {
  mkdirSync(INBOX_DIR, { recursive: true })
  await loadDeliveredIds()
  log(`replay start: ${INBOX_DIR}`)
  await processInboxDir(true)
  log('replay done')
}

// ---- fs.watch + fallback poll ----------------------------------------------

function startWatcher(): void {
  try {
    let debounce: ReturnType<typeof setTimeout> | null = null
    watch(INBOX_DIR, { persistent: false }, (_event, filename) => {
      if (
        !filename ||
        filename.endsWith('.tmp') ||
        filename.endsWith('.delivered') ||
        filename.endsWith('.delivering')
      ) return
      if (debounce) clearTimeout(debounce)
      debounce = setTimeout(() => { void processInboxDir() }, 100)
    })
    log(`watching ${INBOX_DIR}`)
  } catch (err) {
    log(`WARN: watch failed: ${err}`)
  }

  const t = setInterval(() => { void processInboxDir() }, POLL_INTERVAL_MS)
  t.unref()
}

// ---- SQLite helpers --------------------------------------------------------

function openDbReadonly(): Database {
  return new Database(DB_PATH, { readonly: true })
}

interface Peer {
  pubkey: string; owner_name: string | null; owner_handle: string | null; added_at: number
}

async function coveList(): Promise<{ peers: Peer[] }> {
  try { await stat(DB_PATH) } catch { return { peers: [] } }
  const db = openDbReadonly()
  try {
    return {
      peers: db.query<Peer, []>(
        `SELECT pubkey, owner_name, owner_handle, added_at FROM trust_list ORDER BY added_at DESC`,
      ).all(),
    }
  } catch { return { peers: [] } } finally { db.close() }
}

interface InviteRow {
  id: string; pubkey: string; owner_name: string | null
  owner_handle: string | null; preview: string | null; expires_at: number
}

async function covePendingInvites(): Promise<{ invites: unknown[] }> {
  try { await stat(DB_PATH) } catch { return { invites: [] } }
  const db = openDbReadonly()
  try {
    const now = Date.now()
    const rows = db.query<InviteRow, [number]>(
      `SELECT id, pubkey, owner_name, owner_handle, preview, expires_at
       FROM invites WHERE status = 'pending' AND expires_at > ? ORDER BY expires_at ASC`,
    ).all(now)
    return {
      invites: rows.map(r => ({
        invite_id: r.id,
        pubkey: r.pubkey,
        owner_name: r.owner_name,
        owner_handle: r.owner_handle,
        preview: r.preview,
        expires_at: new Date(r.expires_at).toISOString(),
      })),
    }
  } catch { return { invites: [] } } finally { db.close() }
}

async function coveMypubkey(): Promise<{ pubkey: string }> {
  const raw = await readFile(CERT_PATH, 'utf8')
  const cert = JSON.parse(raw) as Record<string, unknown>
  const pubkey = cert['agent_pubkey'] as string | undefined
  if (!pubkey || !/^[0-9a-f]{64}$/.test(pubkey)) {
    throw new Error('CERT_INVALID: agent_pubkey missing or malformed')
  }
  return { pubkey }
}

// ---- cove_recv -------------------------------------------------------------

interface InboxMessage {
  id: string; from_pubkey: string; from_display: string; text: string; ts: string
}

interface RawInboxFile {
  params?: {
    content?: string
    meta?: {
      from_pubkey?: string; owner_name?: string; owner_handle?: string
      ts?: string; received_at?: string; envelope_id?: string
    }
  }
}

async function coveRecv(opts: {
  since?: string; limit?: number; readAck?: boolean
}): Promise<{ messages: InboxMessage[] }> {
  const limit = Math.min(opts.limit ?? 50, 200)
  const sinceMs = opts.since ? new Date(opts.since).getTime() : 0
  const ack = opts.readAck !== false

  let entries: string[]
  try { entries = await readdir(INBOX_DIR) } catch { return { messages: [] } }

  const jsonFiles = entries.filter(f => f.endsWith('.json') && !f.endsWith('.tmp'))
  const msgs: InboxMessage[] = []

  for (const f of jsonFiles) {
    const fp = join(INBOX_DIR, f)
    try {
      const raw = await readFile(fp, 'utf8')
      const parsed = JSON.parse(raw) as RawInboxFile
      const meta = parsed.params?.meta ?? {}
      const content = (parsed.params?.content ?? '').trim()

      const tagAttrs = parseChannelTag(content)
      let text: string
      let from_pubkey: string
      let ts: string
      let from_display: string

      if (tagAttrs) {
        text = tagAttrs.plaintext
        from_pubkey = tagAttrs.chat_id
        ts = tagAttrs.ts
        from_display = tagAttrs.user
      } else {
        // Legacy writeInboxMessage format (plain content, meta.from_pubkey)
        text = content
        from_pubkey = meta.from_pubkey ?? ''
        ts = meta.ts ?? meta.received_at ?? ''
        from_display = [meta.owner_name, meta.owner_handle].filter(Boolean).join(' ')
      }

      if (!ts || !from_pubkey) continue
      if (sinceMs && new Date(ts).getTime() <= sinceMs) continue

      msgs.push({ id: f.replace(/\.json$/, ''), from_pubkey, from_display, text, ts })
    } catch { continue }
  }

  msgs.sort((a, b) => a.ts < b.ts ? -1 : a.ts > b.ts ? 1 : 0)
  const page = msgs.slice(0, limit)

  if (ack && page.length > 0) {
    const readDir = join(COVE_STATE_DIR, 'inbox', 'read')
    try {
      await mkdir(readDir, { recursive: true })
      await Promise.all(page.map(async (m) => {
        const src = join(INBOX_DIR, m.id + '.json')
        const dst = join(readDir, m.id + '.json')
        try { await rename(src, dst) } catch {}
      }))
    } catch {}
  }

  return { messages: page }
}

// ---- File-drop command helper (accept/reject/rehello) ----------------------

async function dropCommand(action: string, payload: Record<string, unknown>): Promise<void> {
  await mkdir(COMMANDS_DIR, { recursive: true })
  const ts = new Date().toISOString().replace(/[:.]/g, '').slice(0, 15)
  const filename = `${ts}-${action}-${randomUUID().slice(0, 8)}.json`
  const tmp = join(COMMANDS_DIR, filename + '.tmp')
  const final = join(COMMANDS_DIR, filename)
  await writeFile(tmp, JSON.stringify({
    action, ...payload, ts: new Date().toISOString(), source: 'cove-plugin',
  }))
  await rename(tmp, final)
}

async function resolveInvitePrefix(prefix: string): Promise<string | null> {
  try { await stat(DB_PATH) } catch { return null }
  const db = openDbReadonly()
  try {
    const row = db.query<{ id: string }, [string]>(
      `SELECT id FROM invites WHERE id LIKE ? AND status = 'pending' ORDER BY expires_at DESC LIMIT 1`,
    ).get(`${prefix}%`)
    return row?.id ?? null
  } finally { db.close() }
}

// ---- Tool definitions -------------------------------------------------------

const TOOLS = [
  {
    name: 'cove_my_pubkey',
    description: "Return this agent's Ed25519 public key (64 hex chars). Share with peers so they can send a friend_request.",
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'cove_send',
    description: 'Send a message to a trusted Cove peer. Returns status "friend_request_sent" if peer not yet trusted. Returns ok:false only for daemon failures.',
    inputSchema: {
      type: 'object', required: ['to_pubkey', 'text'],
      properties: {
        to_pubkey: { type: 'string', description: '64-hex pubkey or 8+ char prefix; daemon resolves prefix against trust_list.' },
        text: { type: 'string', maxLength: 4096 },
      },
      additionalProperties: false,
    },
  },
  {
    name: 'cove_recv',
    description: 'Poll inbox for received messages. Returns messages in chronological order.',
    inputSchema: {
      type: 'object',
      properties: {
        since: { type: 'string', description: 'ISO-8601 timestamp; return messages strictly after this.' },
        limit: { type: 'number', minimum: 1, maximum: 200, description: 'Max results (default 50).' },
        read_ack: { type: 'boolean', description: 'Move returned messages to inbox/read/ (default true).' },
      },
      additionalProperties: false,
    },
  },
  {
    name: 'cove_list',
    description: 'List trusted peers from the local trust_list.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'cove_pending_invites',
    description: 'List pending inbound friend_requests awaiting accept/reject.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'cove_accept',
    description: 'Accept a pending friend_request by invite_id (full id or 8+ char prefix). Daemon processes the accept and adds peer to trust_list.',
    inputSchema: {
      type: 'object', required: ['invite_id'],
      properties: { invite_id: { type: 'string', description: 'Full id or 8+ char hex prefix.' } },
      additionalProperties: false,
    },
  },
  {
    name: 'cove_reject',
    description: 'Reject a pending friend_request by invite_id (full id or 8+ char prefix). Daemon adds peer to block_list.',
    inputSchema: {
      type: 'object', required: ['invite_id'],
      properties: { invite_id: { type: 'string', description: 'Full id or 8+ char hex prefix.' } },
      additionalProperties: false,
    },
  },
  {
    name: 'cove_rehello',
    description: "Re-send a friend_request (hello) to a trusted peer to rebuild the X25519 session key. Use when cove_send returns SESSION_KEY_LOST or DecryptionFailed — ask the peer to also cove_rehello back.",
    inputSchema: {
      type: 'object', required: ['pubkey'],
      properties: { pubkey: { type: 'string', description: '64-hex Ed25519 pubkey of the peer.' } },
      additionalProperties: false,
    },
  },
] as const

// ---- Tool dispatch ----------------------------------------------------------

async function handleTool(
  name: string | undefined,
  args: Record<string, unknown>,
): Promise<unknown> {
  switch (name) {
    case 'cove_my_pubkey':
      return await coveMypubkey()

    case 'cove_send': {
      const to_pubkey = String(args.to_pubkey ?? '')
      const text = String(args.text ?? '')
      if (!to_pubkey || !text) throw new Error('to_pubkey and text are required')
      const res = await daemonOp({ to_pubkey, text })
      if (res.ok) return { ok: true, status: 'sent' }
      if (res.error === 'NOT_TRUSTED') return { ok: true, status: 'friend_request_sent', hint: '邀請已寄給對方，等對方 accept 後訊息會送達' }
      if (res.error?.includes('shared key') || res.error?.includes('No shared key')) {
        return { ok: false, error: 'SESSION_KEY_LOST', hint: '對方需要重新 hello — 雙方都執行 cove_rehello' }
      }
      return { ok: false, error: res.error ?? 'DAEMON_DOWN' }
    }

    case 'cove_recv':
      return await coveRecv({
        since: args.since as string | undefined,
        limit: args.limit as number | undefined,
        readAck: args.read_ack as boolean | undefined,
      })

    case 'cove_list':
      return await coveList()

    case 'cove_pending_invites':
      return await covePendingInvites()

    case 'cove_accept': {
      const invite_id = String(args.invite_id ?? '')
      if (!invite_id) throw new Error('invite_id required')
      const fullId = await resolveInvitePrefix(invite_id)
      if (!fullId) return { ok: false, error: 'NOT_FOUND' }
      await dropCommand('accept', { invite_id: fullId })
      return { ok: true, hint: '指令已送出，daemon 將處理' }
    }

    case 'cove_reject': {
      const invite_id = String(args.invite_id ?? '')
      if (!invite_id) throw new Error('invite_id required')
      const fullId = await resolveInvitePrefix(invite_id)
      if (!fullId) return { ok: false, error: 'NOT_FOUND' }
      await dropCommand('reject', { invite_id: fullId })
      return { ok: true, hint: '指令已送出，daemon 將處理' }
    }

    case 'cove_rehello': {
      const pubkey = String(args.pubkey ?? '')
      if (!pubkey) throw new Error('pubkey required')
      // Try socket with op:rehello (needs daemon ≥ cv4 patch)
      const res = await daemonOp({ op: 'rehello', pubkey })
      if (res.ok) return { ok: true, hint: '已送出 hello，等對方也執行 cove_rehello 完成雙向握手' }
      // Fallback: file-drop command (daemon handles on next watch cycle)
      if (res.error === 'DAEMON_DOWN' || res.error?.includes('missing')) {
        await dropCommand('rehello', { pubkey_prefix: pubkey })
        return { ok: true, hint: '已放入 command queue，daemon 重新連線後執行' }
      }
      return { ok: false, error: res.error }
    }

    default:
      throw new Error(`unknown tool: ${name}`)
  }
}

// ---- MCP Server ------------------------------------------------------------

async function main(): Promise<void> {
  log(`starting. inbox=${INBOX_DIR} sock=${SOCK_PATH}`)

  mcp = new Server(
    { name: 'cove', version: '0.0.1' },
    { capabilities: { tools: {}, notifications: {} } },
  )

  mcp.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }))

  mcp.setRequestHandler(CallToolRequestSchema, async (req) => {
    const name = req.params.name
    const args = (req.params.arguments ?? {}) as Record<string, unknown>
    try {
      const payload = await handleTool(name, args)
      return { content: [{ type: 'text', text: JSON.stringify(payload, null, 2) }] }
    } catch (err) {
      return {
        content: [{ type: 'text', text: JSON.stringify({ ok: false, error: String(err) }) }],
        isError: true,
      }
    }
  })

  const transport = new StdioServerTransport()
  await mcp.connect(transport)
  log('MCP connected')

  await replayInbox()
  startWatcher()

  log('ready')
}

main().catch(err => { log('fatal:', String(err)); process.exit(1) })
