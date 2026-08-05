import { authorize, type OperationClass } from "./authorization.ts";

type Request = { action: string; operationClass: OperationClass; target?: string; breakGlass?: { reason: string; issuedAtMs: number } };
const now = 1_000_000;
function before(request: Request) {
  // Exact pre-removal behavior for requests the only caller can create: it
  // supplied action and operationClass, never guardHealthy.
  if (request.target?.startsWith("/home/oldrabbit/.claude-bots/shared/diana-resident")) return { decision: "DENY", reason: "never_touch" };
  if (request.operationClass === "recovery") return new Set(["restart_approved_pod", "clean_expired_clone", "clean_disk", "terminate_verified_orphan"]).has(request.action)
    ? { decision: "ALLOW", reason: "recovery_static_action" } : { decision: "DENY", reason: "unknown_recovery_action" };
  const bg = request.breakGlass;
  if (!bg || !bg.reason.trim() || bg.issuedAtMs > now || now - bg.issuedAtMs > 30 * 60 * 1000) return { decision: "DENY", reason: bg ? "break_glass_expired" : "change_not_allowlisted" };
  return { decision: "BREAK_GLASS", reason: "break_glass_requires_independent_notification" };
}
const cases: [string, Request][] = [
  ["recovery-known", { action: "clean_disk", operationClass: "recovery" }],
  ["recovery-unknown", { action: "unknown", operationClass: "recovery" }],
  ["change-break-glass", { action: "edit", operationClass: "change", breakGlass: { reason: "incident", issuedAtMs: now } }],
  ["change-no-break-glass", { action: "edit", operationClass: "change" }],
  ["never-touch", { action: "edit", operationClass: "change", target: "/home/oldrabbit/.claude-bots/shared/diana-resident/authorization.ts", breakGlass: { reason: "incident", issuedAtMs: now } }],
];
let failed = 0;
for (const [name, request] of cases) {
  const oldResult = before(request); const newResult = authorize(request, now);
  const same = oldResult.decision === newResult.decision && oldResult.reason === newResult.reason;
  console.log(`${same ? "PASS" : "FAIL"}: ${name} before=${oldResult.decision}/${oldResult.reason} after=${newResult.decision}/${newResult.reason}`);
  if (!same) failed++;
}
process.exitCode = failed ? 1 : 0;
