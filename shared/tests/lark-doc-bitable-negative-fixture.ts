#!/usr/bin/env bun
import { mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  APPROVED_SCOPES,
  LarkDocError,
  atomicWriteSecure,
  getAccessToken,
  type Paths,
  type TokenRecord,
} from "../bin/lark-doc-lib.ts";

const root = mkdtempSync(join(tmpdir(), "lark-doc-bitable-negative-"));
const runtime = join(root, "runtime");
const logs = join(root, "logs");
mkdirSync(runtime, { mode: 0o700 });
mkdirSync(logs, { mode: 0o700 });
const paths: Paths = {
  token: join(runtime, "oauth-token.json"),
  pending: join(runtime, "oauth-pending.json"),
  lock: join(runtime, "refresh.lock"),
  audit: join(logs, "audit.jsonl"),
};
const expired: TokenRecord = {
  version: 1,
  access_token: "fixture-expired-access",
  refresh_token: "fixture-expired-refresh",
  token_type: "Bearer",
  scope: [...APPROVED_SCOPES],
  verified_user_id: "fixture-owner",
  access_expires_at: "2020-01-01T00:00:00.000Z",
  refresh_expires_at: "2020-01-01T00:00:00.000Z",
};

try {
  atomicWriteSecure(paths.token, expired);
  await getAccessToken({
    appId: "fixture-app",
    appSecret: "fixture-secret",
    expectedUserId: "fixture-owner",
    paths,
    fetch: async () => {
      throw new Error("expired credentials must fail before API fetch");
    },
  });
  console.error("NEGATIVE_AUTH_RESULT=UNEXPECTED_SUCCESS");
  process.exitCode = 1;
} catch (error) {
  if (!(error instanceof LarkDocError) || error.kind !== "auth_failed") throw error;
  console.log("NEGATIVE_AUTH_EXIT=1");
  console.log(`NEGATIVE_AUTH_ERROR=${error.message}`);
  console.log("NEGATIVE_AUTH_ROWS_RETURNED=0");
  console.log("NEGATIVE_AUTH_OBSERVABLE=PASS");
} finally {
  rmSync(root, { recursive: true, force: true });
}
