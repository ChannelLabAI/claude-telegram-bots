# HTML Attachment Preview Ops Runbook

Scope: a7b8 implementation only. This task does not reload production services.

1. Merge reviewed code.
2. Set DNS/tunnel hostname `attach.channellab.io`.
3. Add the ingress entry from `infra/cloudflared/attach-channellab-ingress.yml` before the catch-all rule.
4. Set `MVP_ATTACH_ORIGIN=https://attach.channellab.io` and a stable `MVP_ATTACH_PREVIEW_SECRET`.
5. In the ops window, reload cloudflared and restart MVP only after Bella approval.
6. Live QA must use a browser against real `https://attach.channellab.io` for N1-N9, especially cookie isolation.

Security invariants:

- `mvp_session` stays host-only. Never add `Domain=.channellab.io`.
- Main `mvp.channellab.io` must never inline-serve uploaded HTML.
- Attach origin exposes no app API routes; `/api/*` returns 404.
- Preview URLs are HMAC-signed and short-lived.
- Preview iframes use `sandbox="allow-scripts"` only.
