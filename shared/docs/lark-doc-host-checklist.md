# `lark-doc` host verification

Run only after Bella approves the implementation. Do not paste tokens, OAuth
codes, secrets, or document content into task evidence.

1. In the existing Anya Lark app, enable exactly:
   `auth:user.id:read`, `docx:document:readonly`, `offline_access`,
   `sheets:spreadsheet:readonly`, `wiki:wiki:readonly`. Confirm no Drive,
   contacts, wildcard, or write scope is enabled.
2. Register `http://127.0.0.1:8765/lark-doc/oauth/callback`. Store the stable
   老兔 user ID in root-managed Secret Manager secret
   `lark-owner-user-id-anya`; only the host administrators may change it.
3. Run `shared/bin/lark-doc auth start`, review the consent screen, authorize as
   老兔, then pipe the complete browser callback URL to
   `shared/bin/lark-doc auth finish` on stdin.
4. Record only mode/owner output (never content):
   `stat -c '%a %U %n' bots/anya/runtime/lark-doc
   bots/anya/runtime/lark-doc/oauth-token.json
   bots/anya/logs/lark-doc-read-audit.jsonl`.
5. Prove both runtime paths are ignored with `git check-ignore -v`, and prove
   neither is tracked or staged with `git ls-files --error-unmatch` (expected
   non-zero).
6. Read labeled private fixtures: direct docx, wiki→docx, wiki→sheet, and direct
   sheet. Compare representative Markdown in the terminal to Lark UI, but record
   only labels, exits, byte counts, and audit request IDs.
7. Check no-permission, deleted/invalid, legacy `/docs/`, and `/base/` links.
   Each must have a human error and matching terminal audit record.
8. Force or await expiry, run two concurrent reads, and confirm exactly one token
   refresh plus successful reread. Record only before/after token-file hashes.
9. Revoke the user grant after testing if this is not the production approval
   window. No service restart is needed.
