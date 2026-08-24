# VPS → Mac asynchronous relay contract

This directory is the VPS outbox for the non-resident `mac-agent`. The Mac-side
SessionStart hook pulls pending `*.json` files from the directory root. No VPS
daemon pushes to the Mac, and this directory is separate from the pod-system
`relay/` inbox used for Mac → VPS messages.

Canonical paths:

- pending: `/home/oldrabbit/.claude-bots/relay-to-mac/*.json`
- completed: `/home/oldrabbit/.claude-bots/relay-to-mac/archive/*.json`
- contract: `/home/oldrabbit/.claude-bots/relay-to-mac/README.md`

## Filename and identity

Use `<UTC timestamp>-<sender>-<UUID>.json`, for example:

`20260822T132500Z-anya-3f7da582-82d4-4f26-bf05-50eb99f1b4a3.json`

The filename stem is the immutable `message_id`. Writers must use a new UUID
for every logical message and must never replace an existing pending or archived
file. Consumers process filenames in bytewise lexical order; the UUID prevents
same-second collisions.

## JSON envelope

The file is UTF-8 JSON with one object and a trailing newline. Required fields:

| Field | Type | Meaning |
|---|---|---|
| `message_id` | non-empty string | Exact filename without `.json`; idempotency key. |
| `from_bot` | non-empty string | VPS sender identity, for example `anya`. |
| `recipient` | string | Must be `mac-agent` for this outbox. |
| `ts` | RFC 3339 string | Creation time with `Z` or an explicit UTC offset. |
| `text` | string | Complete message body; an empty string is valid. |

Optional fields:

| Field | Type | Meaning |
|---|---|---|
| `thread_id` | non-empty string | Stable conversation identifier. |
| `in_reply_to` | non-empty string | Parent `message_id`; requires `thread_id`. |
| `purpose` | string | One of `discussion`, `status_request`, `clarification`, `proposal_review`. |
| `requires_reply` | boolean | Whether the sender expects a later Mac → VPS relay reply. |

Unknown fields must be preserved when archiving and ignored by consumers unless
a later contract defines them. Example:

```json
{
  "message_id": "20260822T132500Z-anya-3f7da582-82d4-4f26-bf05-50eb99f1b4a3",
  "from_bot": "anya",
  "recipient": "mac-agent",
  "ts": "2026-08-22T21:25:00+08:00",
  "text": "Please inspect the attached incident summary on the VPS.",
  "thread_id": "auth-recovery-20260822",
  "purpose": "status_request",
  "requires_reply": true
}
```

## Writer protocol (VPS)

1. Construct the final filename and envelope; make `message_id` equal the stem.
2. Create a dot-prefixed temporary file in this same directory with mode `0600`.
3. Write the full JSON, flush and close it.
4. Publish atomically without overwrite. On Linux, create the final name with
   `link(2)` and then unlink the temporary name; an equivalent no-clobber
   same-filesystem operation is acceptable.
5. A collision is an error: choose a new UUID. Never truncate or replace the
   existing file.

Readers ignore dotfiles and names that do not end in `.json`, so an interrupted
write cannot become a message.

## SessionStart consumer protocol (Mac)

1. Over SSH, list only root-level `*.json` files in bytewise lexical order.
2. For each file, read the complete bytes and parse one JSON object. Confirm all
   required fields/types, `recipient == "mac-agent"`, and `message_id` equals
   the filename stem.
3. Deduplicate by `message_id`. Processing is **at least once**: a disconnect can
   happen after local handling but before acknowledgement, so repeated IDs must
   not repeat side effects.
4. Only after successful local handling, atomically move the unchanged VPS file
   to `archive/<same filename>` without overwrite.
5. On parse, validation, handling, or archive collision failure, leave the
   pending file untouched and report the exact filename. Never silently delete
   or archive a failed message.

The Mac agent replies through the opposite channel by atomically writing a
pod-system relay envelope to `/home/oldrabbit/.claude-bots/relay/`, using
`from_bot: "mac-agent"` and the intended VPS bot in `recipient`. This task does
not implement the Mac SessionStart hook itself.

## Operational observations

- Pending age is the delivery signal: a root-level JSON left across sessions is
  still unacknowledged.
- `archive/` is an immutable audit trail. Do not edit or recycle archived IDs.
- There is deliberately no claim that SSH confines Mac writes to this outbox;
  Mac remains the same-uid out-of-band maintenance channel.

## Verified observations — first end-to-end run, 2026-08-24

Before this date both directions had zero real traffic (`relay-to-mac/` pending
0, `archive/` 0, no `from_bot: mac-agent` envelope in `relay/read/`). Anya sent
`20260824T103357Z-anya-5cdecac5-…`; mac-agent archived it and replied through
`relay/` as `20260824T103759Z-mac-agent-184f41a4-…`. Round trip: 4m02s. The
notes below record what the run exposed; they document existing behaviour and
add no new requirements.

- **`archive/` is the de-duplication ledger, and only for archiving.** The
  consumer protocol requires dedup by `message_id` but names no ledger. In
  practice the no-clobber archive move *is* one: a repeated ID fails `link(2)`
  with `EEXIST` and the pending file stays put as a reportable event. Do not
  build a second ledger. But note the limit — this guarantees *no duplicate
  archiving*, not *idempotent side effects*. Delivery is at-least-once, so a
  consumer whose handling has side effects must check `archive/` for the same
  `message_id` **before** acting, not rely on the move to protect it.
- **Bytewise ordering needs `LC_ALL=C`.** Step 1 says bytewise lexical order,
  but a shell glob sorts under `LC_COLLATE`. Current filenames are pure ASCII so
  there is no live divergence; set `LC_ALL=C` to keep it that way if the
  filename charset ever widens.
- **Prefer `link(2)`+`unlink(2)` over `mv -n` when archiving.** GNU `mv -n`
  skips silently and still exits 0 when the target exists, which turns a
  collision into an invisible no-op; `link(2)` fails hard with `EEXIST`, so the
  collision becomes an observable, reportable event.
- The published file ends up mode `0600`, inherited from the `0600` temporary
  file through `link(2)`. This is fine while both ends run as the same uid, and
  is the first thing that would break if a consumer ever runs as another user.
