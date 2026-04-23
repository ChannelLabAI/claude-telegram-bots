#!/usr/bin/env bun
// server.ts — Cove channel plugin for Claude Code (cv5-b2: pull model)
//
// Decision C: pull model. Daemon writes *.json to INBOX_DIR; Anya calls cove_recv
// on demand. No auto-inject, no fs.watch. Daemon (anya-cove-daemon.ts) stays as
// independent systemd process.
//
// Tools: cove_send (daemon socket), cove_recv (direct inbox read),
//        cove_list / cove_my_pubkey / cove_pending_invites (SQLite/cert),
//        cove_accept / cove_reject (file-drop command), cove_rehello (socket+fallback)

import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import { ListToolsRequestSchema, CallToolRequestSchema } from '@modelcontextprotocol/sdk/types.js'
import { existsSync, watch } from 'node:fs'
import { readFile, rename, stat, readdir, writeFile, mkdir } from 'node:fs/promises'
import { join } from 'node:path'
import { homedir } from 'node:os'
import { createConnection } from 'node:net'
import { randomUUID } from 'node:crypto'
import { Database } from 'bun:sqlite'

// ---- Config ----------------------------------------------------------------

const HOME = process.env.HOME ?? homedir()
const COVE_STATE_DIR = process.env.COVE_STATE_DIR ?? join(HOME, '.claude-bots', 'state', 'anya')
// COVE_INBOX_DIR: where writeInboxMessage writes and cove_recv reads (cove-messages/ avoids TG inbox collision)
const INBOX_DIR = process.env.COVE_INBOX_DIR ?? join(HOME, '.claude-bots', 'bots', 'anya', 'inbox', 'cove-messages')
const SOCK_PATH = process.env.COVE_SOCK ?? join(HOME, '.claude-bots', 'bots', 'anya', 'services', 'cove', 'cove-send.sock')
const DB_PATH = process.env.COVE_DB ?? join(HOME, '.claude-bots', 'bots', 'anya', 'services', 'cove', 'invites.db')
const CERT_PATH = process.env.COVE_CERT ?? join(HOME, '.cove', 'agents', 'anya', 'cert.json')
const COMMANDS_DIR = process.env.COVE_COMMANDS_DIR ?? join(HOME, '.claude-bots', 'bots', 'anya', 'inbox', 'cove-commands')

const DAEMON_TIMEOUT_MS = 5_000

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

// ---- cv4→cv5 migration: move legacy .delivered/.delivering to inbox/read/ ---
// Called once at startup. Idempotent: rename fails silently if file already gone.

export async function migrateDeliveredFiles(
  inboxDir = INBOX_DIR,
  stateDir = COVE_STATE_DIR,
): Promise<number> {
  const readDir = join(stateDir, 'inbox', 'read')
  try {
    const entries = await readdir(inboxDir)
    const legacy = entries.filter(f => f.endsWith('.delivered') || f.endsWith('.delivering'))
    if (legacy.length === 0) return 0
    await mkdir(readDir, { recursive: true })
    await Promise.all(legacy.map(async (f) => {
      const src = join(inboxDir, f)
      const dst = join(readDir, f.replace(/\.(delivered|delivering)$/, ''))
      try { await rename(src, dst) } catch {}
    }))
    log(`migrate: moved ${legacy.length} legacy file(s) to inbox/read/`)
    return legacy.length
  } catch { return 0 }
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

export async function coveRecv(opts: {
  since?: string; limit?: number; readAck?: boolean
  _inboxDir?: string; _stateDir?: string
}): Promise<{ messages: InboxMessage[] }> {
  const inboxDir = opts._inboxDir ?? INBOX_DIR
  const stateDir = opts._stateDir ?? COVE_STATE_DIR
  const limit = Math.min(opts.limit ?? 50, 200)
  const sinceMs = opts.since ? new Date(opts.since).getTime() : 0
  const ack = opts.readAck !== false

  let entries: string[]
  try { entries = await readdir(inboxDir) } catch { return { messages: [] } }

  const jsonFiles = entries.filter(f => f.endsWith('.json') && !f.endsWith('.tmp'))
  const msgs: InboxMessage[] = []

  for (const f of jsonFiles) {
    const fp = join(inboxDir, f)
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
    const readDir = join(inboxDir, 'read')
    try {
      await mkdir(readDir, { recursive: true })
      await Promise.all(page.map(async (m) => {
        const src = join(inboxDir, m.id + '.json')
        const dst = join(readDir, m.id + '.json')
        try { await rename(src, dst) } catch {}
      }))
    } catch {}
  }

  return { messages: page }
}

// ---- cv9: inbox watcher + push notification --------------------------------
// Port of Mac packages/cove-mcp/src/index.ts watchInbox()/emitNotification()/processInboxFile().
// VPS uses SDK mcp.notification() instead of raw stdout write.
// VPS moves processed files to read/ (consistent with coveRecv pull model).

function emitNotification(mcp: Server, content: string): void {
  void mcp.notification({ method: 'notifications/claude/channel', params: { content } })
}

async function processInboxFile(mcp: Server, filename: string): Promise<void> {
  const filePath = join(INBOX_DIR, filename)
  const readDir = join(INBOX_DIR, 'read')
  const donePath = join(readDir, filename)

  if (!existsSync(filePath)) return
  if (existsSync(donePath)) return

  let content: string
  try {
    const raw = await readFile(filePath, 'utf8')
    const parsed = JSON.parse(raw) as { params?: { content?: string } }
    content = parsed.params?.content ?? ''
    if (!content) { log(`inbox watcher: empty content in ${filename}, skipping`); return }
  } catch (err) {
    log(`inbox watcher: failed to read ${filename}: ${String(err)}`)
    return
  }

  try {
    emitNotification(mcp, content)
  } catch (err) {
    log(`inbox watcher: emit failed for ${filename}: ${String(err)}`)
    return
  }

  try {
    await mkdir(readDir, { recursive: true })
    await rename(filePath, donePath)
  } catch (err) {
    log(`inbox watcher: move to read/ failed for ${filename}: ${String(err)}`)
  }
}

const _inboxDebounceTimers = new Map<string, ReturnType<typeof setTimeout>>()

export function watchInbox(mcp: Server): void {
  if (!existsSync(INBOX_DIR)) {
    log(`inbox watcher: dir not found (${INBOX_DIR}), skipping`)
    return
  }
  try {
    const watcher = watch(INBOX_DIR, { persistent: false }, (_event, filename) => {
      if (
        !filename ||
        !filename.endsWith('-cove-msg.json') ||
        filename.endsWith('.delivered') ||
        filename.endsWith('.tmp')
      ) return
      const existing = _inboxDebounceTimers.get(filename)
      if (existing) clearTimeout(existing)
      _inboxDebounceTimers.set(
        filename,
        setTimeout(() => {
          _inboxDebounceTimers.delete(filename)
          void processInboxFile(mcp, filename)
        }, 50),
      )
    })
    watcher.on('error', (err) => {
      log(`inbox watcher error (server continues): ${String(err)}`)
    })
    log(`inbox watcher: watching ${INBOX_DIR}`)
  } catch (err) {
    log(`inbox watcher: init failed (server continues): ${String(err)}`)
  }
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

  const mcp = new Server(
    { name: 'cove', version: '0.0.1' },
    {
      capabilities: {
        // cv9: 'claude/channel' registers the notification listener so Claude Code
        // surfaces cove messages as <channel> tags (requires --dangerously-load-development-channels server:cove)
        experimental: { 'claude/channel': {} },
        tools: {},
      },
      instructions:
        'Cove (E2EE peer-to-peer) messages arrive as ' +
        '<channel source="plugin:cove" chat_id="<64-hex-pubkey>" message_id="<64-hex-id>" user="<handle>" ts="<ISO>">plaintext</channel>. ' +
        'chat_id is the sender\'s Ed25519 pubkey. ' +
        'To reply, call cove_send with to_pubkey=chat_id. ' +
        'These are direct peer-to-peer messages, not Telegram.',
    },
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
  await migrateDeliveredFiles()
  await mcp.connect(transport)
  watchInbox(mcp) // cv9: push notifications for incoming cove messages
  log('ready')
}

main().catch(err => { log('fatal:', String(err)); process.exit(1) })
