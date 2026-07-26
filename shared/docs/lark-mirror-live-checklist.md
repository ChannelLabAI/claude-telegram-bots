# Lark mirror post-QA live checklist

Run only after reviewer approval and host apply. Never copy access/refresh
tokens, document bodies, regex matches, or Lark CLI credential files into FATQ
evidence.

1. Confirm `lark-cli` v1.0.77 can make one harmless GET with `--as user`.
   Do not inspect, copy or log its credential store.
2. Copy the checked-in config and set the real Lark hostname. Confirm the
   space allowlist contains exactly `7588969620657147413`,
   `7589941241228332563`, and `7596207127715122709`; the 10-node denylist must
   remain exact. Confirm HR `7588585813969997332` and test
   `7666890650964463131` occur in neither config nor request log.
3. Run `shared/bin/lark-mirror list`. Record space names, type counts,
   `excluded`, and total only. A configured space returning code 0 with zero
   nodes is a failure and must alert; it is never an empty-success result.
   The inventory has 140 docx, while only 4 of the 10 HIGH nodes are docx, so
   the exact token denylist leaves 136 docx candidates—not 130. Do not invent
   six extra exclusions; ask Anya if a 130-document cap is still required.
4. Run the first `sync`. Select at least three real documents, including one
   with a nested list and one with a table. Compare headings, lists, table,
   code, and image source links against Lark UI. Record labels, byte counts and
   result only.
5. Record `written`, `quarantined`, `metadataOnly`, bytes and elapsed time.
   Quarantine records may contain title/source/reason category only. Confirm
   every quarantined body is absent from vault and MemOcean, then run `sync`
   again unchanged. Require `written=0`, unchanged output hashes, and no
   duplicate Radar rows for the same drawer path.
6. Search MemOcean for `NOXCAT` and `MYBW`; record result slugs/titles and
   source paths only. Each query must hit mirrored content.
7. Require fixtures for private key, 0x address, API key, credential label and
   currency amount quarantine. A clean body writes+ingests; a hit stores
   metadata-only quarantine, never writes the body and never ingests.
8. Run a tracked/staged/worktree token scan using only token-shaped patterns.
   Confirm zero real values. Confirm the live provider invokes only
   `lark-cli api GET ... --as user`; no Lark create/update/delete/move/member
   tool or endpoint may be reachable.
9. Confirm `lark-mirror-sync` is registered in
   `shared/config/loop-registry.yml` with its signal, consumer, owner and
   overlap. Its status must be updated from `planned` only when the schedule is
   actually activated. No registry entry means no schedule.
10. After live proof passes and step 9 is satisfied, schedule
    `shared/bin/lark-mirror sync` every 30 minutes. A deployment or schedule
    change does not require restarting any production service.
