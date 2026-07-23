# Claude subscription account switcher (`claude-acct`) runbook

Related: [[reference_claude_acct_account_switch_tool]] · [[bot-watchdog]] · [[401-auth-recovery]]

`claude-acct` switches the Claude subscription credentials used by the fleet.
It is intentionally a small operational tool; do not refactor or extend it while
performing an account switch.

## Commands

```bash
claude-acct status             # current account, live credential summary, and slots
claude-acct use laohu          # switch to the named existing account slot
claude-acct use mitu           # switch to the named existing account slot
```

The executable remains available at `~/.npm-global/bin/claude-acct` as a symlink
to `shared/bin/claude-acct`. The symlink is part of the runtime path contract;
do not replace it with a copied script.

## Two non-negotiable rules

1. **Never restore credentials by manually copying a dated `.bak` file.** Refresh
   tokens rotate. A stale backup can become invalid after that account is used.
   Switch only through `claude-acct use <account>`, which first saves the outgoing
   live credentials into that account's slot.
2. **Quota follows the account, not the worker.** A process restart cannot remove
   a subscription limit. Use the smoke test after a switch to confirm the selected
   account can serve a request.

Credential files, account slots, tokens, `.bak` files, and local status are
operational secrets. They are never committed, pasted into tickets, or included
in logs. Git tracks only this tool and this runbook.

## Before switching: in-flight builder check

1. Announce the intended account and reason in the operations channel; name the
   responsible operator.
2. Inspect FATQ `in_progress` work and active builder workers. Ask each owner
   whether an interactive Claude operation, migration, or test is still running.
3. Wait for an explicit safe point, or record the affected task and obtain the
   coordinator's decision before continuing. Do not silently terminate work.
4. Confirm no credential-recovery operation is currently modifying
   `~/.claude/.credentials.json` or `~/.claude/accounts/`.
5. Run `claude-acct status`. Record only the selected account and pass/fail
   outcome—never credential values or expiry timestamps—in the operations note.

## Switching and smoke test

1. Run `claude-acct use <existing-account>`.
2. The tool saves the outgoing live credential into its slot, installs the target
   slot, recycles **Claude workers only**, then runs a 60-second `claude -p`
   smoke test. Gateway and Codex processes are not intentionally targeted.
3. Treat `OK` as the required functional smoke-test result. A `WARN` means the
   switch completed but authentication or quota must be investigated; do not claim
   recovery solely from the copy operation.
4. Run `claude-acct status` afterwards and record the selected account plus
   smoke-test pass/fail. Do not publish `access_exp` or credential metadata.

## Watchdog / HTTP 401 relationship

A bot watchdog signal or HTTP 401 is an incident symptom, not permission to copy
a backup credential. First use `claude-acct status`, check whether a concurrent
switch is active, and follow the team's 401/auth-recovery incident procedure.
If an account switch is authorised, perform the in-flight check above and use
the tool's smoke test. Escalate persistent 401s or a failed smoke test with only
the account name, timestamps, and sanitized error category.

## Version-control and review checks

Before submitting an update to this tool, verify all of the following:

```bash
git diff --check
git grep -nEI '(refresh[_-]?token|access[_-]?token|authorization:[[:space:]]*bearer|sk-ant-|oauth)' -- shared/bin/claude-acct shared/docs/claude-acct-runbook.md
git check-ignore -q .claude/accounts/fixture.json
git check-ignore -q .claude/.credentials.json
```

The grep should find only explanatory identifiers, never a credential value.
For a behavior-preserving adoption, compare `claude-acct status` before and after
the symlink points at the tracked file; redacted output must be byte-identical.

## Security review observations (adoption scope)

The adoption preserves existing behavior. The script has no token printing path:
`status` prints subscription type, expiry, and a yes/no refresh-token indicator.
It does write and copy credential files, so it must run only under the intended
user account. Existing logic does not explicitly set a restrictive `umask`,
validate account names, or chmod the outgoing slot after saving it. Those are
hardening candidates, but changing them is deliberately outside this adoption;
open a separate behaviour-change task before altering that path.
