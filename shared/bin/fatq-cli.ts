#!/home/oldrabbit/.bun/bin/bun
/**
 * fatq-cli.ts — FATQ 統一寫入層 (Part 1 only)
 *
 * Per spec: handover/fatq-cli-and-approval-spec-20260707.md (Anya, Pod 2.1 FATQ side, v1)
 * Implements Part 1 subcommands only: create, claim, submit, verdict (approve|reject),
 * reassign, comment, query, hold.  Part 2 (approval_pending state machine) is NOT implemented.
 *
 * NOTE: spec §1.2 names the deliverable `fatq-cli.sh` (bash+jq); this implementation was
 * explicitly commissioned as TypeScript on bun runtime — behavior contract (§1.2–§1.5)
 * is followed verbatim, only the implementation language differs.
 *
 * Write discipline (§1.4): flock -x (via libc through bun:ffi) around the whole
 * read-re-verify-modify-rename sequence; JSON updates are written to a same-directory
 * .tmp file then renamed over the original; cross-directory state transitions are a
 * second rename. Post-lock re-verification (file still at expected path/inode, state
 * and permission fields unchanged) guards against races (§1.5).
 *
 * Exit codes (§1.4): 0 ok, 2 E_USAGE, 3 E_PERM, 4 E_STATE, 5 E_VERIFY, 6 E_CONFLICT, 7 E_NOTFOUND.
 *
 * Env:
 *   FATQ_ROOT         tasks dir            (default /home/oldrabbit/.claude-bots/tasks)
 *                     — same convention as fatq-watch.sh
 *   FATQ_TEAM_CONFIG  team-config.json     (default /home/oldrabbit/.claude-bots/shared/team-config.json)
 *   FATQ_VERIFY_SH    fatq-verify.sh path  (default /home/oldrabbit/.claude-bots/shared/bin/fatq-verify.sh)
 *   FATQ_IDENTITY     identity fallback when --as is not given (§1.3.1, flag wins)
 */

import {
  closeSync,
  fstatSync,
  openSync,
  readFileSync,
  readdirSync,
  renameSync,
  statSync,
  writeFileSync,
  existsSync,
} from "node:fs";
import { basename, join } from "node:path";
import { spawnSync } from "node:child_process";
import { dlopen, FFIType } from "bun:ffi";

// ---------------------------------------------------------------- constants

const FATQ_ROOT = process.env.FATQ_ROOT ?? "/home/oldrabbit/.claude-bots/tasks";
const TEAM_CONFIG =
  process.env.FATQ_TEAM_CONFIG ?? "/home/oldrabbit/.claude-bots/shared/team-config.json";
const VERIFY_SH =
  process.env.FATQ_VERIFY_SH ?? "/home/oldrabbit/.claude-bots/shared/bin/fatq-verify.sh";

// Core state dirs per spec §1.2 transition table (E1: CLI only recognizes these;
// drafts/proposals/reviews/design_review/etc. are never touched by the CLI).
const CORE_STATES = ["pending", "in_progress", "review", "rejected", "done"] as const;
type State = (typeof CORE_STATES)[number];

const EXIT = { OK: 0, USAGE: 2, PERM: 3, STATE: 4, VERIFY: 5, CONFLICT: 6, NOTFOUND: 7 } as const;
const CODE: Record<number, string> = {
  2: "E_USAGE",
  3: "E_PERM",
  4: "E_STATE",
  5: "E_VERIFY",
  6: "E_CONFLICT",
  7: "E_NOTFOUND",
};

// flock(2) via libc — spec §1.4 mandates flock -x around read-modify-rename.
const LOCK_EX = 2;
let _libc: any = null;
function flockExclusive(fd: number): void {
  if (_libc === null) {
    _libc = dlopen("libc.so.6", {
      flock: { args: [FFIType.i32, FFIType.i32], returns: FFIType.i32 },
    });
  }
  const rc = _libc.symbols.flock(fd, LOCK_EX);
  if (rc !== 0) throw new Error(`flock failed rc=${rc}`);
}

// ---------------------------------------------------------------- output helpers

let JSON_MODE = false;

function fail(exit: number, message: string, extra?: Record<string, unknown>): never {
  if (JSON_MODE) {
    console.log(JSON.stringify({ ok: false, code: CODE[exit] ?? "E_UNKNOWN", message, ...extra }));
  }
  console.error(`[fatq-cli] ${message}`); // stderr always carries one human-readable line (§1.4)
  process.exit(exit);
}

function succeed(payload: Record<string, unknown>, humanLine: string): never {
  if (JSON_MODE) console.log(JSON.stringify({ ok: true, ...payload }));
  else console.log(`[fatq-cli] ${humanLine}`);
  process.exit(EXIT.OK);
}

// ---------------------------------------------------------------- time

/** ISO8601 in +08:00, per feedback_timezone_utc8 / spec §1.4 */
function nowISO8(): string {
  const d = new Date(Date.now() + 8 * 3600 * 1000);
  return d.toISOString().replace(/\.\d{3}Z$/, "") + "+08:00";
}

const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?([+-]\d{2}:\d{2}|Z)$/;

// ---------------------------------------------------------------- identity (§1.3)

interface Team {
  known: Set<string>;
  builders: Set<string>;
  reviewers: Set<string>;
}

function loadTeam(): Team {
  let cfg: any;
  try {
    cfg = JSON.parse(readFileSync(TEAM_CONFIG, "utf8"));
  } catch (e) {
    fail(EXIT.USAGE, `cannot read team config at ${TEAM_CONFIG}: ${e}`);
  }
  const known = new Set<string>();
  const builders = new Set<string>();
  const reviewers = new Set<string>();
  for (const a of cfg.assistants ?? []) if (a.state_dir) known.add(String(a.state_dir).toLowerCase());
  for (const [pool, members] of Object.entries(cfg.shared_pools ?? {})) {
    for (const m of members as any[]) {
      if (!m.state_dir) continue;
      const id = String(m.state_dir).toLowerCase();
      known.add(id);
      if (pool === "builder") builders.add(id);
      if (pool === "reviewer") reviewers.add(id);
    }
  }
  // §1.3.1 / E5: identity list = team-config ∪ {mac-agent, laotu}
  known.add("mac-agent");
  known.add("laotu");
  // §1.3.2 lists mac-agent in the builder category
  builders.add("mac-agent");
  return { known, builders, reviewers };
}

/** Resolve --as / FATQ_IDENTITY (flag wins). Missing → exit 2. Unknown → exit 3. (§1.3.1) */
function resolveIdentity(asFlag: string | undefined, team: Team, required = true): string | null {
  const raw = asFlag ?? process.env.FATQ_IDENTITY;
  if (!raw) {
    if (!required) return null;
    fail(EXIT.USAGE, "identity not declared: use --as <identity> or FATQ_IDENTITY (no guessing)");
  }
  const id = raw.toLowerCase(); // lowercase normalize (§1.3.1)
  if (!team.known.has(id)) {
    fail(EXIT.PERM, `identity "${id}" is not in the known identity list (team-config ∪ {mac-agent, laotu})`, {
      rule: "identity must be in shared/team-config.json ∪ {mac-agent, laotu}",
    });
  }
  return id;
}

// ---------------------------------------------------------------- task lookup

interface FoundTask {
  path: string;
  state: State;
  file: string;
  obj: any;
}

function taskIdOf(obj: any): string | null {
  // D3: never parse info from filename — read JSON. Some legacy queue entries
  // (type:"triage") use "id" instead of "task_id"; accept both for lookup.
  return obj?.task_id ?? obj?.id ?? null;
}

function findTask(taskId: string): FoundTask | null {
  for (const state of CORE_STATES) {
    const dir = join(FATQ_ROOT, state);
    if (!existsSync(dir)) continue;
    for (const f of readdirSync(dir)) {
      if (!f.endsWith(".json")) continue;
      const p = join(dir, f);
      let obj: any;
      try {
        obj = JSON.parse(readFileSync(p, "utf8"));
      } catch {
        continue; // tolerate broken/non-task files (read side must not error, E3)
      }
      if (taskIdOf(obj) === taskId) return { path: p, state, file: f, obj };
    }
  }
  return null;
}

function lc(v: unknown): string {
  return typeof v === "string" ? v.toLowerCase() : "";
}

// ---------------------------------------------------------------- history (§1.4)

function makeHistory(
  by: string,
  action: string,
  from: State | null,
  to: State | null,
  extra?: Record<string, unknown>,
): Record<string, unknown> {
  const h: Record<string, unknown> = { ts: nowISO8(), by, via: "fatq-cli", action };
  if (from) h.from = `${from}/`;
  if (to) h.to = `${to}/`;
  if (extra) Object.assign(h, extra);
  return h;
}

// ---------------------------------------------------------------- verify gate (§1.2 submit / verdict approve, E6)

function runVerifyGate(taskPath: string): { pass: boolean; output: string; exit: number } {
  const r = spawnSync("bash", [VERIFY_SH, taskPath], { encoding: "utf8", timeout: 600_000 });
  const out = `${r.stdout ?? ""}${r.stderr ?? ""}`;
  const code = r.status ?? 2;
  // E6: ANY non-zero exit blocks (1 = AC fail, 2 = sick task file) — no skip flag.
  return { pass: code === 0, output: out, exit: code };
}

// ---------------------------------------------------------------- locked mutation core (§1.4/§1.5)

interface MutateOpts {
  task: FoundTask;
  identity: string;
  action: string;
  toState: State | null; // null = in-place update (comment/hold)
  /** re-verification predicate run again after the lock is held; return error string to abort */
  recheck: (obj: any) => string | null;
  mutate: (obj: any) => void;
  historyExtra?: Record<string, unknown>;
  verifyGate?: boolean;
}

function lockedMutate(o: MutateOpts): { from: State; to: State | null; history: Record<string, unknown> } {
  const { task } = o;
  let fd: number;
  try {
    fd = openSync(task.path, "r+");
  } catch {
    fail(EXIT.CONFLICT, `task file vanished before locking: ${task.path} (moved by a concurrent writer?)`);
  }
  try {
    flockExclusive(fd); // blocking exclusive lock (§1.5)

    // Post-lock re-read + re-verify (feedback_dryrun_staleness_recheck_at_write):
    // file must still exist at the expected path AND be the same inode we locked.
    let st;
    try {
      st = statSync(task.path);
    } catch {
      fail(EXIT.CONFLICT, `lost race: ${task.file} no longer in ${task.state}/ (concurrent transition won)`);
    }
    if (st.ino !== fstatSync(fd).ino) {
      fail(EXIT.CONFLICT, `lost race: ${task.file} was replaced concurrently in ${task.state}/`);
    }
    let obj: any;
    try {
      obj = JSON.parse(readFileSync(task.path, "utf8"));
    } catch {
      fail(EXIT.CONFLICT, `re-read failed: ${task.file} is no longer valid JSON`);
    }
    const rc = o.recheck(obj);
    if (rc) fail(EXIT.CONFLICT, `post-lock re-verification failed: ${rc}`);

    // Verify gate runs while the lock is held so the gated file cannot move mid-check.
    if (o.verifyGate) {
      const v = runVerifyGate(task.path);
      if (!v.pass) {
        process.stderr.write(v.output); // print fail detail (§1.2 submit)
        fail(EXIT.VERIFY, `verify gate failed (fatq-verify.sh exit ${v.exit}) — transition blocked`, {
          verify_exit: v.exit,
        });
      }
    }

    // Mutate + standardized history append (forward-only, E3: legacy lines untouched)
    o.mutate(obj);
    const hist = makeHistory(o.identity, o.action, task.state, o.toState, o.historyExtra);
    if (!Array.isArray(obj.history)) obj.history = [];
    obj.history.push(hist);
    if (o.toState) obj.status = o.toState; // status field mirrors directory (observed in real tasks; C7 allows status)

    // Atomic write: same-dir .tmp → rename over original → (optionally) rename across dirs (§1.4-1)
    const tmp = `${task.path}.tmp`;
    writeFileSync(tmp, JSON.stringify(obj, null, 2) + "\n");
    renameSync(tmp, task.path);
    let finalPath = task.path;
    if (o.toState && o.toState !== task.state) {
      finalPath = join(FATQ_ROOT, o.toState, task.file);
      renameSync(task.path, finalPath);
    }
    return { from: task.state, to: o.toState ?? task.state, history: hist };
  } finally {
    try {
      closeSync(fd); // releases flock
    } catch {}
  }
}

// ---------------------------------------------------------------- arg parsing

interface Args {
  positional: string[];
  flags: Map<string, string | true>;
}

function parseArgs(argv: string[]): Args {
  const positional: string[] = [];
  const flags = new Map<string, string | true>();
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--")) {
      const name = a.slice(2);
      const next = argv[i + 1];
      if (next !== undefined && !next.startsWith("--")) {
        flags.set(name, next);
        i++;
      } else {
        flags.set(name, true);
      }
    } else {
      positional.push(a);
    }
  }
  return { positional, flags };
}

function flagStr(args: Args, name: string): string | undefined {
  const v = args.flags.get(name);
  return typeof v === "string" ? v : undefined;
}

// ---------------------------------------------------------------- transition permission helpers (§1.3.2)

function requireAssignedSelf(identity: string, obj: any, team: Team, transition: string): void {
  // builder-category transitions: identity must be in builder set (or anya, who has
  // "all of the above") AND task.assigned == identity. Strict matrix reading —
  // identities outside the builder category (assistants/designer/laotu) are refused
  // even if assigned, failing closed (noted as a spec ambiguity).
  if (!(team.builders.has(identity) || identity === "anya")) {
    fail(EXIT.PERM, `identity "${identity}" 不得執行 ${transition}（規則：builder 類轉移僅限 builder pool ∪ {mac-agent, anya}）`, {
      rule: "builder-category transition requires builder identity (§1.3.2)",
    });
  }
  if (lc(obj.assigned) !== identity) {
    fail(EXIT.PERM, `identity "${identity}" 不得執行 ${transition}（規則：僅限 assigned == 自己，本單 assigned=${obj.assigned ?? "null"}）`, {
      rule: "only task.assigned may perform this transition (§1.2)",
    });
  }
}

function requireVerdictAllowed(identity: string, obj: any, verb: string): void {
  // E4 reviewer-of-record model: allowed = task.reviewer ∪ {bella, anya}
  const reviewer = lc(obj.reviewer);
  if (!(identity === reviewer || identity === "bella" || identity === "anya")) {
    fail(EXIT.PERM, `identity "${identity}" 不得執行 verdict ${verb}（規則：僅 task reviewer 欄位者 ∪ {bella, anya}，本單 reviewer=${obj.reviewer ?? "null"}）`, {
      rule: "verdict allowed = task.reviewer ∪ {bella, anya} (E4)",
    });
  }
  // 禁自審 — no exceptions (§1.2)
  if (identity === lc(obj.assigned)) {
    fail(EXIT.PERM, `identity "${identity}" 不得執行 verdict ${verb}（規則：禁自審，identity == assigned）`, {
      rule: "self-review forbidden: identity == task.assigned (§1.2 verdict)",
    });
  }
}

function requireState(task: FoundTask, allowed: State[], transition: string): void {
  if (!allowed.includes(task.state)) {
    fail(
      EXIT.STATE,
      `illegal transition: task ${taskIdOf(task.obj)} is in ${task.state}/, ${transition} requires ${allowed.map((s) => s + "/").join(" or ")}`,
    );
  }
}

function mustFind(taskId: string): FoundTask {
  const t = findTask(taskId);
  if (!t) fail(EXIT.NOTFOUND, `task not found in ${CORE_STATES.join("/, ")}/: ${taskId}`);
  return t;
}

// ---------------------------------------------------------------- subcommands

function cmdCreate(args: Args, team: Team, identity: string): never {
  // Required block-spec fields (§1.2 create): missing any → exit 2
  const REQUIRED = [
    "goal",
    "background",
    "context",
    "deliverables",
    "acceptance-criteria",
    "out-of-scope",
    "review-focus",
  ];
  const missing = REQUIRED.filter((k) => !flagStr(args, k));
  const slug = flagStr(args, "slug");
  if (!slug) missing.unshift("slug");
  if (missing.length) {
    fail(EXIT.USAGE, `create: missing required field(s): ${missing.map((m) => "--" + m).join(", ")}`);
  }
  if (!/^[a-z0-9][a-z0-9-]*$/.test(slug!)) {
    fail(EXIT.USAGE, `create: --slug must be lowercase [a-z0-9-]: got "${slug}"`);
  }

  const arr = (name: string): string[] => {
    const v = flagStr(args, name)!;
    if (v.trim().startsWith("[")) {
      try {
        const parsed = JSON.parse(v);
        if (Array.isArray(parsed)) return parsed.map(String);
      } catch {}
      fail(EXIT.USAGE, `create: --${name} looks like JSON but does not parse as an array`);
    }
    return [v];
  };

  const assigned = flagStr(args, "assigned");
  const reviewer = flagStr(args, "reviewer");
  for (const [label, v] of [
    ["assigned", assigned],
    ["reviewer", reviewer],
  ] as const) {
    if (v && !team.known.has(v.toLowerCase())) {
      fail(EXIT.USAGE, `create: --${label} "${v}" is not a known identity`);
    }
  }

  let verifyCommands: unknown[] | undefined;
  const vcRaw = flagStr(args, "verify-commands");
  if (vcRaw) {
    try {
      const parsed = JSON.parse(vcRaw);
      if (!Array.isArray(parsed)) throw new Error("not an array");
      verifyCommands = parsed;
    } catch (e) {
      fail(EXIT.USAGE, `create: --verify-commands must be a JSON array: ${e}`);
    }
  }

  // Filename convention {YYYYMMDD-HHmm}-{4hex}-{slug}.json (§1.2, observed in real tasks/)
  const now = nowISO8(); // 2026-07-07T12:34:56+08:00
  const stamp = now.slice(0, 16).replace(/-/g, "").replace("T", "-").replace(":", ""); // YYYYMMDD-HHmm
  const pendingDir = join(FATQ_ROOT, "pending");
  if (!existsSync(pendingDir)) fail(EXIT.USAGE, `tasks root has no pending/ dir: ${FATQ_ROOT}`);

  let taskId = "";
  let path = "";
  let written = false;
  for (let attempt = 0; attempt < 5 && !written; attempt++) {
    const hex = Math.floor(Math.random() * 0x10000)
      .toString(16)
      .padStart(4, "0");
    taskId = `${stamp}-${hex}-${slug}`;
    path = join(pendingDir, `${taskId}.json`);
    const hist = makeHistory(identity, "create", null, "pending");
    const obj: Record<string, unknown> = {
      task_id: taskId,
      slug,
      status: "pending",
      priority: flagStr(args, "priority") ?? "P2",
      assigned: assigned ? assigned.toLowerCase() : null,
      reviewer: reviewer ? reviewer.toLowerCase() : null,
      fast_track: args.flags.get("fast-track") === true,
      created_at: now,
      created_by: identity,
      goal: flagStr(args, "goal"),
      background: flagStr(args, "background"),
      context: flagStr(args, "context"),
      deliverables: arr("deliverables"),
      acceptance_criteria: arr("acceptance-criteria"),
      out_of_scope: arr("out-of-scope"),
      review_focus: flagStr(args, "review-focus"),
      ...(verifyCommands ? { verify_commands: verifyCommands } : {}),
      history: [hist],
    };
    try {
      writeFileSync(path, JSON.stringify(obj, null, 2) + "\n", { flag: "wx" }); // exclusive create
      written = true;
      succeed(
        { task_id: taskId, from: null, to: "pending/", history_appended: hist, path },
        `created ${taskId} → pending/`,
      );
    } catch (e: any) {
      if (e?.code !== "EEXIST") fail(EXIT.USAGE, `create failed writing ${path}: ${e}`);
      // EEXIST → retry with a new 4hex
    }
  }
  fail(EXIT.USAGE, `create: could not find a free 4hex filename after 5 attempts`);
}

function cmdClaim(args: Args, team: Team, identity: string): never {
  const taskId = args.positional[0];
  if (!taskId) fail(EXIT.USAGE, "usage: fatq-cli claim <task_id> --as <identity>");
  const task = mustFind(taskId);
  requireAssignedSelf(identity, task.obj, team, `claim（${task.state} → in_progress）`);
  requireState(task, ["pending", "rejected"], "claim"); // pending→in_progress or rejected→in_progress (§1.2)
  const r = lockedMutate({
    task,
    identity,
    action: "claim",
    toState: "in_progress",
    recheck: (obj) =>
      lc(obj.assigned) !== identity ? `assigned changed to ${obj.assigned ?? "null"}` : null,
    mutate: () => {},
  });
  succeed(
    { task_id: taskId, from: `${r.from}/`, to: "in_progress/", history_appended: r.history },
    `claimed ${taskId}: ${r.from}/ → in_progress/`,
  );
}

function cmdSubmit(args: Args, team: Team, identity: string): never {
  const taskId = args.positional[0];
  if (!taskId) fail(EXIT.USAGE, "usage: fatq-cli submit <task_id> --as <identity>");
  const task = mustFind(taskId);
  requireAssignedSelf(identity, task.obj, team, "submit（in_progress → review）");
  requireState(task, ["in_progress"], "submit");
  const r = lockedMutate({
    task,
    identity,
    action: "submit",
    toState: "review",
    verifyGate: true, // built-in verify gate, ANY non-zero blocks (§1.2 submit, E6); no skip flag
    recheck: (obj) =>
      lc(obj.assigned) !== identity ? `assigned changed to ${obj.assigned ?? "null"}` : null,
    mutate: () => {},
  });
  succeed(
    { task_id: taskId, from: "in_progress/", to: "review/", history_appended: r.history },
    `submitted ${taskId}: in_progress/ → review/ (verify gate passed)`,
  );
}

function cmdVerdict(args: Args, team: Team, identity: string): never {
  const verb = args.positional[0];
  const taskId = args.positional[1];
  if (verb !== "approve" && verb !== "reject") {
    fail(EXIT.USAGE, "usage: fatq-cli verdict approve|reject <task_id> --as <identity> [--reason ...]");
  }
  if (!taskId) fail(EXIT.USAGE, `usage: fatq-cli verdict ${verb} <task_id> --as <identity>`);
  const reason = flagStr(args, "reason");
  if (verb === "reject" && !reason) {
    fail(EXIT.USAGE, "verdict reject: --reason is required (builder 修復要有依據, §1.2)");
  }
  const task = mustFind(taskId);
  requireVerdictAllowed(identity, task.obj, verb);
  requireState(task, ["review"], `verdict ${verb}`);
  const toState: State = verb === "approve" ? "done" : "rejected";
  const r = lockedMutate({
    task,
    identity,
    action: `verdict_${verb}`,
    toState,
    verifyGate: verb === "approve", // approve re-runs fatq-verify.sh; fail → blocked (§1.2, C4)
    recheck: (obj) => {
      const rev = lc(obj.reviewer);
      if (!(identity === rev || identity === "bella" || identity === "anya"))
        return `reviewer changed to ${obj.reviewer ?? "null"}`;
      if (identity === lc(obj.assigned)) return `assigned changed — would now be self-review`;
      return null;
    },
    mutate: () => {},
    historyExtra: reason ? { reason } : undefined,
  });
  succeed(
    { task_id: taskId, from: "review/", to: `${toState}/`, history_appended: r.history },
    `verdict ${verb}: ${taskId} review/ → ${toState}/`,
  );
}

function cmdReassign(args: Args, team: Team, identity: string): never {
  const taskId = args.positional[0];
  if (!taskId) fail(EXIT.USAGE, "usage: fatq-cli reassign <task_id> --as anya [--to <bot>]");
  if (identity !== "anya") {
    fail(EXIT.PERM, `identity "${identity}" 不得執行 reassign（規則：僅 anya，§1.2）`, {
      rule: "reassign is anya-only (§1.2)",
    });
  }
  const to = flagStr(args, "to");
  if (to && !team.known.has(to.toLowerCase())) {
    fail(EXIT.USAGE, `reassign: --to "${to}" is not a known identity`);
  }
  const task = mustFind(taskId); // any state → pending (§1.2)
  const r = lockedMutate({
    task,
    identity,
    action: "reassign",
    toState: "pending",
    recheck: () => null, // anya's universal reset key — no field precondition beyond existence
    mutate: (obj) => {
      obj.assigned = to ? to.toLowerCase() : null; // no --to = clear (unassigned_alert path)
    },
    historyExtra: { assigned: to ? to.toLowerCase() : null },
  });
  succeed(
    { task_id: taskId, from: `${r.from}/`, to: "pending/", history_appended: r.history },
    `reassigned ${taskId}: ${r.from}/ → pending/ (assigned=${to ? to.toLowerCase() : "null"})`,
  );
}

function cmdComment(args: Args, _team: Team, identity: string): never {
  const taskId = args.positional[0];
  const text = flagStr(args, "text") ?? args.positional.slice(1).join(" ");
  if (!taskId || !text) fail(EXIT.USAGE, 'usage: fatq-cli comment <task_id> --text "..." --as <identity>');
  const task = mustFind(taskId);
  const r = lockedMutate({
    task,
    identity,
    action: "comment",
    toState: null, // no state change, no other field touched (§1.2)
    recheck: () => null,
    mutate: () => {},
    historyExtra: { reason: text },
  });
  succeed(
    { task_id: taskId, from: null, to: null, history_appended: r.history },
    `comment appended to ${taskId} (state ${task.state}/ unchanged)`,
  );
}

function cmdHold(args: Args, _team: Team, identity: string): never {
  const taskId = args.positional[0];
  if (!taskId) fail(EXIT.USAGE, "usage: fatq-cli hold <task_id> --until <ISO8601|now> | --clear");
  const clear = args.flags.get("clear") === true;
  const until = flagStr(args, "until");
  if (!clear && !until) fail(EXIT.USAGE, "hold: need --until <ISO8601> or --clear");
  let value: string | null = null;
  if (!clear) {
    if (until === "now") {
      value = nowISO8(); // 解除＝--until now (§1.2)
    } else {
      if (!ISO_RE.test(until!) || Number.isNaN(Date.parse(until!))) {
        fail(EXIT.USAGE, `hold: --until must be ISO8601 with offset (e.g. 2026-07-09T02:00:00+08:00): got "${until}"`);
      }
      value = until!;
    }
  }
  const task = mustFind(taskId);
  // hold permission: anya + task assigned 本人 (§1.2)
  if (!(identity === "anya" || identity === lc(task.obj.assigned))) {
    fail(EXIT.PERM, `identity "${identity}" 不得執行 hold（規則：anya ＋ task assigned 本人，本單 assigned=${task.obj.assigned ?? "null"}）`, {
      rule: "hold allowed for anya + task.assigned (§1.2)",
    });
  }
  const r = lockedMutate({
    task,
    identity,
    action: "hold",
    toState: null, // writes existing not_before field only (E8), no state change
    recheck: (obj) =>
      identity === "anya" || identity === lc(obj.assigned)
        ? null
        : `assigned changed to ${obj.assigned ?? "null"}`,
    mutate: (obj) => {
      obj.not_before = value;
    },
    historyExtra: { until: value },
  });
  succeed(
    { task_id: taskId, from: null, to: null, history_appended: r.history, not_before: value },
    `hold ${taskId}: not_before=${value ?? "cleared"}`,
  );
}

function cmdQuery(args: Args, _team: Team): never {
  // read-only, open to anyone (§1.2 query: 任何人; reads are never gated §1.1)
  const state = flagStr(args, "state");
  const assigned = flagStr(args, "assigned");
  const taskId = args.positional[0];

  const summarize = (obj: any, st: string, file: string) => {
    const id = taskIdOf(obj);
    if (!id) return { file, state: st, non_task: true }; // E1: non-task JSON flagged, not parsed as task
    return {
      task_id: id,
      state: st,
      status: obj.status ?? null,
      slug: obj.slug ?? null,
      assigned: obj.assigned ?? null,
      reviewer: obj.reviewer ?? null,
      priority: obj.priority ?? null,
      not_before: obj.not_before ?? null,
      goal: typeof obj.goal === "string" ? obj.goal.slice(0, 120) : null,
    };
  };

  if (taskId) {
    const t = findTask(taskId);
    if (!t) fail(EXIT.NOTFOUND, `task not found: ${taskId}`);
    if (JSON_MODE) console.log(JSON.stringify({ ok: true, state: t.state, path: t.path, task: t.obj }));
    else console.log(JSON.stringify({ state: t.state, path: t.path, task: t.obj }, null, 2));
    process.exit(EXIT.OK);
  }

  const states: State[] = state
    ? (CORE_STATES.includes(state as State)
        ? [state as State]
        : fail(EXIT.USAGE, `query: --state must be one of ${CORE_STATES.join("|")}: got "${state}"`))
    : [...CORE_STATES];

  const rows: any[] = [];
  for (const st of states) {
    const dir = join(FATQ_ROOT, st);
    if (!existsSync(dir)) continue;
    for (const f of readdirSync(dir)) {
      if (!f.endsWith(".json")) continue;
      let obj: any;
      try {
        obj = JSON.parse(readFileSync(join(dir, f), "utf8"));
      } catch {
        rows.push({ file: f, state: st, non_task: true, parse_error: true });
        continue;
      }
      const row = summarize(obj, st, f);
      if (assigned && lc((row as any).assigned) !== assigned.toLowerCase()) continue;
      rows.push(row);
    }
  }
  if (JSON_MODE) console.log(JSON.stringify({ ok: true, count: rows.length, tasks: rows }));
  else {
    for (const r of rows) {
      if (r.non_task) console.log(`  [non-task] ${r.state}/${r.file}`);
      else console.log(`  ${r.state.padEnd(11)} ${r.task_id}  assigned=${r.assigned ?? "-"} reviewer=${r.reviewer ?? "-"} prio=${r.priority ?? "-"}`);
    }
    console.log(`[fatq-cli] ${rows.length} entr${rows.length === 1 ? "y" : "ies"}`);
  }
  process.exit(EXIT.OK);
}

// ---------------------------------------------------------------- main

const USAGE = `fatq-cli — FATQ single write path (Part 1)
usage:
  fatq-cli create --slug <s> --goal ... --background ... --context ... \\
           --deliverables <str|json-array> --acceptance-criteria <...> --out-of-scope <...> \\
           --review-focus <...> [--assigned <bot>] [--reviewer <bot>] [--priority P2] \\
           [--verify-commands '<json>'] --as <identity> [--json]
  fatq-cli claim <task_id> --as <identity>
  fatq-cli submit <task_id> --as <identity>
  fatq-cli verdict approve|reject <task_id> --as <identity> [--reason "..."]
  fatq-cli reassign <task_id> --as anya [--to <bot>]
  fatq-cli comment <task_id> --text "..." --as <identity>
  fatq-cli hold <task_id> --until <ISO8601|now> | --clear --as <identity>
  fatq-cli query [<task_id>] [--state <s>] [--assigned <bot>] [--json]
identity: --as <id> or FATQ_IDENTITY env (flag wins). exit codes: 0 ok / 2 usage / 3 perm / 4 state / 5 verify / 6 conflict / 7 notfound`;

function main(): void {
  const argv = process.argv.slice(2);
  const sub = argv[0];
  const args = parseArgs(argv.slice(1));
  JSON_MODE = args.flags.get("json") === true;

  if (!sub || sub === "help" || sub === "--help") {
    console.log(USAGE);
    process.exit(sub ? EXIT.OK : EXIT.USAGE);
  }

  const team = loadTeam();
  const asFlag = flagStr(args, "as");

  switch (sub) {
    case "create":
      cmdCreate(args, team, resolveIdentity(asFlag, team)!);
      break;
    case "claim":
      cmdClaim(args, team, resolveIdentity(asFlag, team)!);
      break;
    case "submit":
      cmdSubmit(args, team, resolveIdentity(asFlag, team)!);
      break;
    case "verdict":
      cmdVerdict(args, team, resolveIdentity(asFlag, team)!);
      break;
    case "reassign":
      cmdReassign(args, team, resolveIdentity(asFlag, team)!);
      break;
    case "comment":
      cmdComment(args, team, resolveIdentity(asFlag, team)!);
      break;
    case "hold":
      cmdHold(args, team, resolveIdentity(asFlag, team)!);
      break;
    case "query": {
      // query is open to anyone (§1.2); if an identity IS declared, still validate it
      if (asFlag || process.env.FATQ_IDENTITY) resolveIdentity(asFlag, team, false);
      cmdQuery(args, team);
      break;
    }
    // Part 2 (approval) intentionally NOT implemented — out of scope for this delivery.
    case "approval":
      fail(EXIT.USAGE, "approval subcommands are Part 2 (approval_pending state machine) — not implemented in this delivery");
      break;
    default:
      fail(EXIT.USAGE, `unknown subcommand "${sub}"\n${USAGE}`);
  }
}

main();
