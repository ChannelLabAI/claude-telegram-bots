// Server-owned authorization boundary; relay/LLM text never supplies commands.
export type OperationClass = "recovery" | "change";
export type Decision = "ALLOW" | "DENY" | "BREAK_GLASS";
export const NEVER_TOUCH = [
  "/home/oldrabbit/.claude-bots/pod-system/hooks",
  "/home/oldrabbit/.claude-bots/seabed",
  "/home/oldrabbit/.claude-bots/shared/bin/secrets-loader.sh",
  "/home/oldrabbit/.claude-bots/shared/systemd/keeper-diana.service",
  "/home/oldrabbit/.claude-bots/shared/diana-resident",
  "/home/oldrabbit/.claude-bots/bots/keeper/access.json",
  "/home/oldrabbit/.claude-bots/logs",
  "/home/oldrabbit/Documents/Obsidian Vault",
  "/home/oldrabbit/Documents/Obsidian Vault - OldRabbit",
  "/home/oldrabbit/.claude",
  "/home/oldrabbit/.config/gcloud",
] as const;
export const RECOVERY_ACTIONS = new Set([
  "restart_approved_pod", "clean_expired_clone", "clean_disk", "terminate_verified_orphan",
]);
export const CHANGE_ALLOWLIST = new Set<string>();
export interface Request { action: string; operationClass: OperationClass; target?: string; breakGlass?: { reason: string; issuedAtMs: number }; }
export function touchesNeverTouch(target = ""): boolean {
  return NEVER_TOUCH.some(p => target === p || target.startsWith(`${p}/`))
    || /^\/home\/oldrabbit\/\.claude-bots\/bots\/[^/]+\/\.env(?:\.|$)/.test(target)
    || target === "/home/oldrabbit/.env" || target.startsWith("/home/oldrabbit/.env.");
}
export function authorize(request: Request, nowMs = Date.now()): { decision: Decision; reason: string } {
  if (touchesNeverTouch(request.target)) return { decision: "DENY", reason: "never_touch" };
  if (request.operationClass === "recovery") return RECOVERY_ACTIONS.has(request.action)
    ? { decision: "ALLOW", reason: "recovery_static_action" }
    : { decision: "DENY", reason: "unknown_recovery_action" };
  if (CHANGE_ALLOWLIST.has(request.action)) return { decision: "ALLOW", reason: "change_allowlist" };
  const bg = request.breakGlass;
  if (!bg || !bg.reason.trim() || bg.issuedAtMs > nowMs || nowMs - bg.issuedAtMs > 30 * 60 * 1000) return { decision: "DENY", reason: bg ? "break_glass_expired" : "change_not_allowlisted" };
  return { decision: "BREAK_GLASS", reason: "break_glass_requires_independent_notification" };
}
