#!/usr/bin/env bun
// build_owner_map.ts — One-time script to build chat_owner_map from messages table.
// Run: bun run build_owner_map.ts
// Safe: only INSERTs to chat_owner_map and proposal_queue; never deletes rows or .md files.

import { Database } from 'bun:sqlite'

const DB_PATH = '/home/oldrabbit/.claude-bots/memory.db'
const db = new Database(DB_PATH)

// Read auto-threshold from loop_config
const cfgRow = db.query<{ value: string }, []>(
  "SELECT value FROM loop_config WHERE key='owner_auto_threshold'"
).get()
const AUTO_THRESHOLD = cfgRow ? parseFloat(cfgRow.value) : 0.8

// Check owner_mapping_enabled
const enabledRow = db.query<{ value: string }, []>(
  "SELECT value FROM loop_config WHERE key='owner_mapping_enabled'"
).get()
if (enabledRow?.value === '0') {
  console.log('[build_owner_map] disabled via loop_config')
  db.close()
  process.exit(0)
}

console.log(`[build_owner_map] DB: ${DB_PATH}`)
console.log(`[build_owner_map] AUTO_THRESHOLD = ${AUTO_THRESHOLD}`)

// Query: for each chat_id, count messages per user
const rows = db.query<{ chat_id: string; user: string; cnt: number }, []>(
  `SELECT chat_id, user, COUNT(*) as cnt
   FROM messages
   WHERE source='telegram' AND user IS NOT NULL AND user != ''
   GROUP BY chat_id, user
   ORDER BY chat_id, cnt DESC`
).all()

// Group by chat_id
const byChat = new Map<string, Array<{ user: string; cnt: number }>>()
for (const r of rows) {
  if (!byChat.has(r.chat_id)) byChat.set(r.chat_id, [])
  byChat.get(r.chat_id)!.push({ user: r.user, cnt: r.cnt })
}

let autoCount = 0
let proposalCount = 0
const ts = new Date().toISOString()

for (const [chatId, userCounts] of byChat) {
  const total = userCounts.reduce((s, r) => s + r.cnt, 0)
  if (total === 0) continue
  const top = userCounts[0]
  const confidence = top.cnt / total

  if (confidence >= AUTO_THRESHOLD) {
    // Auto-write: confident single owner
    db.run(
      `INSERT OR IGNORE INTO chat_owner_map (chat_id, owner, confidence, method) VALUES (?, ?, ?, 'auto')`,
      [chatId, top.user, confidence]
    )
    autoCount++
  } else {
    // Proposal: ambiguous ownership → queue for human review
    db.run(
      `INSERT INTO proposal_queue (ts, kind, summary, evidence_json, status) VALUES (?, ?, ?, ?, 'pending')`,
      [
        ts,
        'owner_map',
        `chat_id ${chatId}: top=${top.user}(${top.cnt}/${total}) confidence=${confidence.toFixed(2)}`,
        JSON.stringify({ chat_id: chatId, candidates: userCounts.slice(0, 3) }),
      ]
    )
    proposalCount++
  }
}

console.log(`[build_owner_map] chat_owner_map: ${autoCount} auto, ${proposalCount} proposals`)

// Print sample
const sample = db.query<{ chat_id: string; owner: string; confidence: number; method: string }, []>(
  'SELECT chat_id, owner, confidence, method FROM chat_owner_map LIMIT 5'
).all()
if (sample.length > 0) {
  console.log('[build_owner_map] sample rows:')
  for (const row of sample) {
    console.log(`  chat_id=${row.chat_id} owner=${row.owner} conf=${row.confidence.toFixed(2)} method=${row.method}`)
  }
}

db.close()
