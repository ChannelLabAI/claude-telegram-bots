#!/usr/bin/env bash
# a7b8 — HTML attachment safe preview fixture without opening a listener.
set -u
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

BUN=/home/oldrabbit/.bun/bin/bun
SRC="${MVP_SRC:-/home/oldrabbit/.claude-bots/mvp}"

for needle in "ATTACH_ORIGIN" "HTML_ATTACHMENT_MIME" "sandbox=\"allow-scripts\"" "connect-src 'none'"; do
  if ! grep -q "$needle" "$SRC/mvp-server.ts" "$SRC/app.html" 2>/dev/null; then
    echo "FATAL: missing HTML preview support marker: $needle"
    exit 1
  fi
done
if grep -q '"text/html":' "$SRC/mvp-server.ts"; then
  echo "FATAL: text/html was added to ATTACHMENT_ALLOWED_MIME inline whitelist"
  exit 1
fi

FIX=$(mktemp -d /tmp/mvp-html-attach-XXXXXX)
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/gb" "$FIX/mvp" "$FIX/projects/attachments/p1" "$FIX/tasks"/{pending,in_progress,review,done,rejected,cancelled,design_review,approval_pending}
printf '<!doctype html><script>fetch("/api/fleet").catch(()=>{});document.cookie;</script><h1>Deck</h1>' > "$FIX/projects/attachments/p1/deck.html"
printf '{"project_id":"p1","owner":"anya","attachments":[{"file":"deck.html","name":"deck.html","mime":"text/html","size":94,"kind":"html_preview"}]}' > "$FIX/projects/p1.json"

export MVP_SKIP_SERVE=1
export MVP_GB="$FIX/gb"
export MVP_DIR="$FIX/mvp"
export FATQ_ROOT="$FIX/tasks"
export PROJECTS_ROOT="$FIX/projects"
export MVP_PROJECT_ATTACHMENTS_DIR="$FIX/projects/attachments"
export MVP_ATTACH_ORIGIN="http://attach.channellab.io"
export MVP_ATTACH_PREVIEW_SECRET="fixture-secret"
export TEST_SRC="$SRC"

UNIT_JS="$FIX/unit.mjs"
cat > "$UNIT_JS" <<'BUN'
import { readFileSync } from "node:fs";
const mod = await import(process.env.TEST_SRC + "/mvp-server.ts");
const t = mod.__htmlAttachPreviewTest;
let pass = 0, fail = 0;
const ok = (name) => { console.log("OK " + name); pass++; };
const bad = (name, detail="") => { console.log("BAD " + name + (detail ? " " + detail : "")); fail++; };

const cookie = t.sessionCookie(new Request("http://mvp.channellab.io/", { headers: { "x-forwarded-proto": "https" } }), "1", 60);
cookie.includes("mvp_session=") ? ok("session-cookie-issued") : bad("session-cookie-issued", cookie);
cookie.includes("Domain=") ? bad("session-cookie-host-only", cookie) : ok("session-cookie-host-only");
cookie.includes("Secure") ? ok("session-cookie-secure-on-https") : bad("session-cookie-secure-on-https", cookie);

const preview = t.attachPreviewUrl("project", "p1", "deck.html");
preview.startsWith("http://attach.channellab.io/preview/project/p1/deck.html?") ? ok("signed-preview-url-attach-origin") : bad("signed-preview-url-attach-origin", preview);
const url = new URL(preview);
const req = new Request(preview, { headers: { host: "attach.channellab.io" } });
const res = t.attachHostResponse(req, url);
res?.status === 200 ? ok("attach-host-valid-signature-200") : bad("attach-host-valid-signature-200", String(res?.status));
const body = await res.text();
body === readFileSync(process.env.PROJECTS_ROOT + "/attachments/p1/deck.html", "utf8") ? ok("attach-host-serves-exact-html") : bad("attach-host-serves-exact-html");
const csp = res.headers.get("content-security-policy") || "";
csp.includes("connect-src 'none'") ? ok("csp-connect-none") : bad("csp-connect-none", csp);
csp.includes("frame-ancestors https://mvp.channellab.io") ? ok("csp-frame-ancestors-mvp") : bad("csp-frame-ancestors-mvp", csp);
res.headers.get("x-content-type-options") === "nosniff" ? ok("attach-nosniff") : bad("attach-nosniff");

url.searchParams.set("sig", "bad");
t.attachHostResponse(new Request(url.toString(), { headers: { host: "attach.channellab.io" } }), url)?.status === 403 ? ok("tampered-signature-403") : bad("tampered-signature-403");
const apiRes = t.attachHostResponse(new Request("http://attach.channellab.io/api/fleet", { headers: { host: "attach.channellab.io" } }), new URL("http://attach.channellab.io/api/fleet"));
apiRes?.status === 404 ? ok("attach-api-404") : bad("attach-api-404", String(apiRes?.status));

process.exit(fail ? 1 : 0);
BUN
unit_out=$("$BUN" "$UNIT_JS")
unit_code=$?
while read -r line; do
  case "$line" in
    OK*) ok "${line#OK }" ;;
    BAD*) bad "${line#BAD }" ;;
  esac
done <<< "$unit_out"
[ "$unit_code" = "0" ] || FAIL=$((FAIL+1))

grep -q 'sandbox="allow-scripts"' "$SRC/app.html" && ok "iframe sandbox is allow-scripts only" || bad "iframe sandbox missing allow-scripts"
grep -q 'allow-same-origin\\|allow-top-navigation' "$SRC/app.html" && bad "iframe sandbox contains forbidden allow-same-origin/top-navigation" || ok "iframe sandbox excludes allow-same-origin and allow-top-navigation"
grep -q 'const isHtml = att.mime === HTML_ATTACHMENT_MIME' "$SRC/mvp-server.ts" && ok "main-domain HTML path is explicitly detected" || bad "main-domain HTML detection missing"
grep -q 'content-disposition.*attachment' "$SRC/mvp-server.ts" && ok "main-domain non-image attachments are forced download" || bad "main-domain forced download marker missing"

echo
echo "===== 結果：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" = "0" ] || exit 1
