# Customer release internal-identifier inventory

The customer distribution contains the seven exact files in
`customer-distribution-allowlist.txt`. Before this gate was added, all six
identifiers below reached `dist/mvp-server.js`; no other distribution file
contained them.

| Distribution file | Pre-fix identifiers |
|---|---|
| `dist/app.html` | None. |
| `dist/env-manifest.json` | None. |
| `dist/mvp-server.js` | All six denylist identifiers below (eight occurrences). |
| `manifest.sha256` | None. |
| `ops/preflight` | None. |
| `systemd/channellab-mvp.service` | None. |
| `VERSION` | None. |

| Identifier | Previous purpose | Customer handling |
|---|---|---|
| `channellab-prod` | GCP project used by the production-only Secret Manager fallback. | Removed from the customer source. The release does not invoke our GCP project; customer secrets come from its root-owned environment files. |
| `mvp-google-client-id` | Internal Secret Manager name for Google OAuth client ID. | Removed. Customer must set `MVP_GOOGLE_CLIENT_ID`. |
| `mvp-google-client-secret` | Internal Secret Manager name for Google OAuth client secret. | Removed. Customer must set `MVP_GOOGLE_CLIENT_SECRET`. |
| `mvp-public-gate-password` | Internal Secret Manager name for the public viewer password. | Removed. If public mode is enabled, customer must set `MVP_PUBLIC_PASSWORD`. |
| `mvp-admin-gate-password` | Internal Secret Manager name for the admin gate password. | Removed. If public mode is enabled, customer must set `MVP_ADMIN_PASSWORD`. |
| `attach.channellab.io` | Internal attachment-preview origin default. | Removed. Customer must set `MVP_ATTACH_ORIGIN`; the existing preflight and hostname-collision guard validate it. |

The source preparation step is fail-closed: each reviewed production-source
shape must occur exactly once, otherwise the customer build stops instead of
silently shipping an unsanitized or partly sanitized server. The distribution
scanner is a separate final gate and reports every matching file and line.
