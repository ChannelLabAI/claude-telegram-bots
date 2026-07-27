import { authorize } from "./authorization.ts";
let failed = 0;
function check(name: string, yes: boolean) { console.log(`${yes ? "PASS" : "FAIL"}: ${name}`); if (!yes) failed++; }
const now = 1_000_000;
check("recovery action allows without target allowlist", authorize({ action: "clean_disk", operationClass: "recovery" }, now).decision === "ALLOW");
check("unimplemented FATQ recovery actions fail closed", authorize({ action: "clear_stale_fatq_lock", operationClass: "recovery" }, now).reason === "unknown_recovery_action");
check("unknown change fails closed", authorize({ action: "edit_systemd", operationClass: "change" }, now).decision === "DENY");
check("break glass expires at thirty minutes", authorize({ action: "edit_systemd", operationClass: "change", breakGlass: { reason: "incident", issuedAtMs: now - 30 * 60 * 1000 - 1 } }, now).reason === "break_glass_expired");
check("self authorization file is never touch", authorize({ action: "edit_authorization", operationClass: "change", target: "/home/oldrabbit/.claude-bots/shared/diana-resident/authorization.ts", breakGlass: { reason: "incident", issuedAtMs: now } }, now).reason === "never_touch");
check("audit log remains never touch", authorize({ action: "truncate", operationClass: "change", target: "/home/oldrabbit/.claude-bots/logs/diana-ops/actions.log", breakGlass: { reason: "incident", issuedAtMs: now } }, now).reason === "never_touch");
check("Obsidian vault remains never touch", authorize({ action: "delete", operationClass: "change", target: "/home/oldrabbit/Documents/Obsidian Vault/private.md", breakGlass: { reason: "incident", issuedAtMs: now } }, now).reason === "never_touch");
check("credential files remain never touch", authorize({ action: "edit", operationClass: "change", target: "/home/oldrabbit/.claude-bots/bots/keeper/.env.production", breakGlass: { reason: "incident", issuedAtMs: now } }, now).reason === "never_touch");
check("gcloud credentials remain never touch", authorize({ action: "edit", operationClass: "change", target: "/home/oldrabbit/.config/gcloud/application_default_credentials.json", breakGlass: { reason: "incident", issuedAtMs: now } }, now).reason === "never_touch");
check("guard failure keeps recovery available with audit reason", authorize({ action: "clean_disk", operationClass: "recovery", guardHealthy: false }, now).reason === "recovery_guard_unavailable_audit_required");
check("guard failure keeps change fail closed", authorize({ action: "edit_systemd", operationClass: "change", guardHealthy: false }, now).reason === "change_guard_unavailable");
process.exitCode = failed ? 1 : 0;
