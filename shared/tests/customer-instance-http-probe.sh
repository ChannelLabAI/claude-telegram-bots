#!/usr/bin/env bash
set -euo pipefail

url="${CUSTOMER_INSTANCE_URL:-http://127.0.0.1:8091/}"
curl_bin="${CUSTOMER_INSTANCE_CURL_BIN:-curl}"
body_file="$(mktemp)"
trap 'rm -f -- "$body_file"' EXIT

set +e
status="$($curl_bin --silent --show-error --output "$body_file" --write-out '%{http_code}' \
  --connect-timeout 3 --max-time 10 "$url")"
curl_exit=$?
set -e
bytes="$(wc -c < "$body_file" | tr -d '[:space:]')"

printf 'CUSTOMER_INSTANCE_URL=%s\n' "$url"
printf 'CUSTOMER_INSTANCE_CURL_EXIT=%s\n' "$curl_exit"
printf 'CUSTOMER_INSTANCE_HTTP_STATUS=%s\n' "${status:-000}"
printf 'CUSTOMER_INSTANCE_RESPONSE_BYTES=%s\n' "$bytes"

if ((curl_exit != 0)); then
  echo "customer-instance-http-probe: FAIL: request did not complete" >&2
  exit 1
fi
if [[ "$status" == "404" ]]; then
  echo "customer-instance-http-probe: FAIL: default Host still routes the whole instance to 404" >&2
  exit 1
fi
if [[ ! "$status" =~ ^[1-5][0-9][0-9]$ ]]; then
  echo "customer-instance-http-probe: FAIL: invalid HTTP status '$status'" >&2
  exit 1
fi

echo "customer-instance-http-probe: PASS: default Host returned non-404"
