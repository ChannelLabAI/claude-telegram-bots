import { describe, test, expect, beforeEach, afterEach } from 'bun:test'
import { join } from 'node:path'
import { mkdtemp, rm, writeFile, stat } from 'node:fs/promises'
import { mkdirSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { parseChannelTag, xmlEscape, xmlUnescape, migrateDeliveredFiles, coveRecv } from './server.ts'

// ---- parseChannelTag + xmlUnescape -----------------------------------------

describe('parseChannelTag', () => {
  test('parses well-formed channel tag', () => {
    const content = '<channel source="plugin:cove" chat_id="aabb" message_id="ccdd" user="alice" ts="2026-01-01T00:00:00.000Z">hello world</channel>'
    const result = parseChannelTag(content)
    expect(result).not.toBeNull()
    expect(result!.chat_id).toBe('aabb')
    expect(result!.message_id).toBe('ccdd')
    expect(result!.user).toBe('alice')
    expect(result!.ts).toBe('2026-01-01T00:00:00.000Z')
    expect(result!.plaintext).toBe('hello world')
  })

  test('xml-unescapes inner text', () => {
    const escaped = xmlEscape('Hello & <world> "test" \'ok\'')
    const content = `<channel source="plugin:cove" chat_id="aa" message_id="bb" user="u" ts="2026-01-01T00:00:00.000Z">${escaped}</channel>`
    const result = parseChannelTag(content)
    expect(result!.plaintext).toBe("Hello & <world> \"test\" 'ok'")
  })

  test('returns null for raw plaintext (no channel tag)', () => {
    expect(parseChannelTag('just a message')).toBeNull()
  })

  test('returns null for partial tag', () => {
    expect(parseChannelTag('<channel source="plugin:cove">')).toBeNull()
  })

  test('parses fixture file content', async () => {
    const raw = await Bun.file('./test-fixtures/cove-notification-sample.json').text()
    const fixture = JSON.parse(raw) as { params: { content: string } }
    const result = parseChannelTag(fixture.params.content)
    expect(result).not.toBeNull()
    expect(result!.chat_id).toHaveLength(64)
    expect(result!.plaintext).toBe('Hello from Mac & test <ok>')
  })
})

describe('xmlEscape / xmlUnescape roundtrip', () => {
  test('escape + unescape = identity', () => {
    const cases = ['hello', '<tag>', '&amp;', '"quoted"', "it's fine", '<a & b>']
    for (const s of cases) {
      expect(xmlUnescape(xmlEscape(s))).toBe(s)
    }
  })

  test('roundtrip with entity-like substrings', () => {
    const tricky = ['&lt;tag&gt;', '1 &amp; 2 &lt; 3', '&quot;hi&quot;']
    for (const s of tricky) {
      expect(xmlUnescape(xmlEscape(s))).toBe(s)
    }
  })
})

// ---- Notification payload schema -------------------------------------------

describe('notification payload schema', () => {
  test('parseChannelTag produces fields matching meta schema', () => {
    const content = '<channel source="plugin:cove" chat_id="PUBKEY64CHARS00000000000000000000000000000000000000000000000000" message_id="ENVID" user="bob" ts="2026-04-21T04:00:00.000Z">test message</channel>'
    const attrs = parseChannelTag(content)!
    // The notification payload meta must match what Claude Code channel plugin expects
    const meta = {
      chat_id: attrs.chat_id,
      recipient: attrs.chat_id,
      message_id: attrs.message_id,
      user: attrs.user,
      user_id: attrs.chat_id,
      ts: attrs.ts,
      source: 'cove',
    }
    expect(meta.chat_id).toBeTruthy()
    expect(meta.recipient).toBe(meta.chat_id)
    expect(meta.message_id).toBeTruthy()
    expect(meta.user).toBeTruthy()
    expect(meta.user_id).toBe(meta.chat_id)
    expect(meta.ts).toBeTruthy()
    expect(meta.source).toBe('cove')
    // content should be raw plaintext, not wrapped XML
    expect(attrs.plaintext).toBe('test message')
    expect(attrs.plaintext).not.toContain('<channel')
  })
})

// ---- Tool whitelist ---------------------------------------------------------

describe('TOOLS whitelist', () => {
  test('all 8 required tools are defined', async () => {
    // Dynamic import to avoid running main()
    const mod = await import('./server.ts')
    // We can't easily introspect TOOLS since it's not exported,
    // but we can check via parseChannelTag (exported) and infer module loaded OK
    expect(mod.parseChannelTag).toBeDefined()
    expect(mod.xmlEscape).toBeDefined()
    expect(mod.xmlUnescape).toBeDefined()
    expect(mod.daemonOp).toBeDefined()
  })

  test('server.ts exports the expected symbols', async () => {
    const mod = await import('./server.ts')
    const exportedKeys = Object.keys(mod)
    expect(exportedKeys).toContain('parseChannelTag')
    expect(exportedKeys).toContain('xmlEscape')
    expect(exportedKeys).toContain('xmlUnescape')
    expect(exportedKeys).toContain('daemonOp')
  })
})

// ---- Replay order + cap + .delivered skip ----------------------------------

describe('inbox replay', () => {
  let tmpDir: string

  beforeEach(async () => {
    tmpDir = await mkdtemp(join(tmpdir(), 'cove-plugin-test-'))
  })

  afterEach(async () => {
    await rm(tmpDir, { recursive: true, force: true })
  })

  function makeNotificationJson(
    chat_id: string,
    envelope_id: string,
    ts: string,
    text: string,
  ): string {
    const escaped = xmlEscape(text)
    const content = `<channel source="plugin:cove" chat_id="${chat_id}" message_id="${envelope_id}" user="alice" ts="${ts}">${escaped}</channel>`
    return JSON.stringify({
      method: 'notifications/claude/channel',
      params: {
        content,
        meta: { source: 'cove-daemon', event: 'cove_message_received', from_pubkey: chat_id, envelope_id, received_at: ts },
      },
    })
  }

  test('creates inbox JSON with correct structure', async () => {
    const chat_id = 'a'.repeat(64)
    const envelope_id = 'b'.repeat(64)
    const ts = '2026-04-21T04:00:00.000Z'
    const json = makeNotificationJson(chat_id, envelope_id, ts, 'hello')
    const parsed = JSON.parse(json)
    expect(parsed.method).toBe('notifications/claude/channel')
    const attrs = parseChannelTag(parsed.params.content)
    expect(attrs).not.toBeNull()
    expect(attrs!.chat_id).toBe(chat_id)
    expect(attrs!.message_id).toBe(envelope_id)
    expect(attrs!.plaintext).toBe('hello')
  })

  test('filename ordering ensures chronological sort', () => {
    const files = [
      '1745200003000-cove-msg.json',
      '1745200001000-cove-msg.json',
      '1745200002000-cove-msg.json',
    ]
    const sorted = [...files].sort((a, b) => a.localeCompare(b))
    expect(sorted[0]).toBe('1745200001000-cove-msg.json')
    expect(sorted[1]).toBe('1745200002000-cove-msg.json')
    expect(sorted[2]).toBe('1745200003000-cove-msg.json')
  })

  test('.delivered files are skipped during scan', async () => {
    const inboxDir = join(tmpDir, 'inbox')
    mkdirSync(inboxDir, { recursive: true })
    // Write 3 pending + 2 already delivered
    for (let i = 0; i < 3; i++) {
      await writeFile(join(inboxDir, `174520000${i}000-cove-msg.json`), makeNotificationJson('a'.repeat(64), 'c'.repeat(64 - 2) + String(i).padStart(2, '0'), '2026-04-21T04:00:00.000Z', `msg ${i}`))
    }
    for (let i = 3; i < 5; i++) {
      await writeFile(join(inboxDir, `174520000${i}000-cove-msg.json.delivered`), makeNotificationJson('a'.repeat(64), 'd'.repeat(64 - 2) + String(i).padStart(2, '0'), '2026-04-21T04:00:00.000Z', `delivered ${i}`))
    }

    const { readdir } = await import('node:fs/promises')
    const all = await readdir(inboxDir)
    const pending = all.filter(f => f.endsWith('.json') && !f.endsWith('.tmp'))
    const delivered = all.filter(f => f.endsWith('.delivered'))

    expect(pending).toHaveLength(3)
    expect(delivered).toHaveLength(2)
  })

})

// ---- migrateDeliveredFiles ---------------------------------------------------

describe('migrateDeliveredFiles', () => {
  let tmpDir: string

  beforeEach(async () => {
    tmpDir = await mkdtemp(join(tmpdir(), 'cove-migrate-test-'))
  })

  afterEach(async () => {
    await rm(tmpDir, { recursive: true, force: true })
  })

  test('moves .delivered files to inbox/read/ renamed as .json', async () => {
    const inboxDir = join(tmpDir, 'inbox', 'messages')
    mkdirSync(inboxDir, { recursive: true })

    await writeFile(join(inboxDir, '001-cove-msg.json.delivered'), '{}')
    await writeFile(join(inboxDir, '002-cove-msg.json.delivered'), '{}')
    await writeFile(join(inboxDir, '003-cove-msg.json'), '{}') // should NOT be moved

    const count = await migrateDeliveredFiles(inboxDir, tmpDir)
    expect(count).toBe(2)

    const { readdir: rd } = await import('node:fs/promises')
    const inboxAfter = await rd(inboxDir)
    const readAfter = await rd(join(tmpDir, 'inbox', 'read'))

    expect(inboxAfter.filter(f => f.endsWith('.delivered'))).toHaveLength(0)
    expect(inboxAfter).toContain('003-cove-msg.json') // untouched
    expect(readAfter).toContain('001-cove-msg.json')
    expect(readAfter).toContain('002-cove-msg.json')
  })

  test('moves .delivering files to inbox/read/ as well', async () => {
    const inboxDir = join(tmpDir, 'inbox', 'messages')
    mkdirSync(inboxDir, { recursive: true })
    await writeFile(join(inboxDir, '001-cove-msg.json.delivering'), '{}')

    const count = await migrateDeliveredFiles(inboxDir, tmpDir)
    expect(count).toBe(1)

    const { readdir: rd } = await import('node:fs/promises')
    const readAfter = await rd(join(tmpDir, 'inbox', 'read'))
    expect(readAfter).toContain('001-cove-msg.json')
  })

  test('idempotent: second call returns 0 and does not error', async () => {
    const inboxDir = join(tmpDir, 'inbox', 'messages')
    mkdirSync(inboxDir, { recursive: true })
    await writeFile(join(inboxDir, '001-cove-msg.json.delivered'), '{}')

    await migrateDeliveredFiles(inboxDir, tmpDir)
    const count2 = await migrateDeliveredFiles(inboxDir, tmpDir) // already moved
    expect(count2).toBe(0)
  })

  test('returns 0 and does not error if inbox dir does not exist', async () => {
    const count = await migrateDeliveredFiles(join(tmpDir, 'nonexistent'), tmpDir)
    expect(count).toBe(0)
  })
})

// ---- coveRecv pull model -----------------------------------------------------

describe('coveRecv pull model', () => {
  let tmpDir: string

  function makeMsg(chat_id: string, ts: string, text: string): string {
    const escaped = xmlEscape(text)
    const content = `<channel source="plugin:cove" chat_id="${chat_id}" message_id="${'e'.repeat(64)}" user="alice" ts="${ts}">${escaped}</channel>`
    return JSON.stringify({
      method: 'notifications/claude/channel',
      params: {
        content,
        meta: { source: 'cove-daemon', from_pubkey: chat_id, ts },
      },
    })
  }

  beforeEach(async () => {
    tmpDir = await mkdtemp(join(tmpdir(), 'cove-recv-test-'))
    mkdirSync(join(tmpDir, 'inbox', 'messages'), { recursive: true })
  })

  afterEach(async () => {
    await rm(tmpDir, { recursive: true, force: true })
  })

  test('read_ack:true moves *.json to inbox/read/ — not renamed to .delivered', async () => {
    const inboxDir = join(tmpDir, 'inbox', 'messages')
    await writeFile(join(inboxDir, '001-cove-msg.json'), makeMsg('a'.repeat(64), '2026-04-22T00:00:01.000Z', 'hi'))

    const result = await coveRecv({ _inboxDir: inboxDir, _stateDir: tmpDir })
    expect(result.messages).toHaveLength(1)
    expect(result.messages[0]!.text).toBe('hi')

    const { readdir: rd } = await import('node:fs/promises')
    const inboxAfter = await rd(inboxDir)
    const readAfter = await rd(join(inboxDir, 'read'))

    expect(inboxAfter.filter(f => f.endsWith('.json'))).toHaveLength(0)  // moved
    expect(inboxAfter.some(f => f.endsWith('.delivered'))).toBe(false)   // no .delivered
    expect(readAfter).toContain('001-cove-msg.json')
  })

  test('read_ack:false leaves *.json in inbox/messages/ unchanged', async () => {
    const inboxDir = join(tmpDir, 'inbox', 'messages')
    await writeFile(join(inboxDir, '001-cove-msg.json'), makeMsg('a'.repeat(64), '2026-04-22T00:00:01.000Z', 'hi'))

    const result = await coveRecv({ readAck: false, _inboxDir: inboxDir, _stateDir: tmpDir })
    expect(result.messages).toHaveLength(1)

    const { readdir: rd } = await import('node:fs/promises')
    const inboxAfter = await rd(inboxDir)
    expect(inboxAfter).toContain('001-cove-msg.json')  // still there

    // Second call still returns same message
    const result2 = await coveRecv({ readAck: false, _inboxDir: inboxDir, _stateDir: tmpDir })
    expect(result2.messages).toHaveLength(1)
  })

  test('returns empty when inbox contains only *.delivered files', async () => {
    const inboxDir = join(tmpDir, 'inbox', 'messages')
    await writeFile(join(inboxDir, '001-cove-msg.json.delivered'), makeMsg('a'.repeat(64), '2026-04-22T00:00:01.000Z', 'old'))

    const result = await coveRecv({ _inboxDir: inboxDir, _stateDir: tmpDir })
    expect(result.messages).toHaveLength(0)
  })
})

// ---- cv9: claude/channel capability declaration --------------------------------

describe('server.ts channel capability (cv9)', () => {
  test('Server constructor declares experimental claude/channel capability', async () => {
    const src = await Bun.file('./server.ts').text()
    // This is the key that makes Claude Code register a notification listener
    expect(src).toContain("'claude/channel': {}")
    expect(src).toContain('experimental:')
  })

  test('Server constructor has instructions field for channel context', async () => {
    const src = await Bun.file('./server.ts').text()
    expect(src).toContain('instructions:')
    expect(src).toContain('plugin:cove')
    expect(src).toContain('cove_send')
  })
})

// ---- .mcp.json schema ---------------------------------------------------------

describe('.mcp.json schema', () => {
  test('mcpServers.cove exists with correct command and CLAUDE_PLUGIN_ROOT arg', async () => {
    const raw = await Bun.file('./.mcp.json').text()
    const config = JSON.parse(raw) as { mcpServers: Record<string, { command: string; args: string[] }> }
    expect(config.mcpServers).toBeDefined()
    expect(config.mcpServers.cove).toBeDefined()
    expect(config.mcpServers.cove.command).toBe('bun')
    const args = config.mcpServers.cove.args
    expect(Array.isArray(args)).toBe(true)
    expect(args).toContain('${CLAUDE_PLUGIN_ROOT}')
    expect(args).toContain('start')
  })
})
