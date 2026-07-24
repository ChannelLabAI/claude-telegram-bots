#!/usr/bin/env bun
import {
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { basename, join } from "node:path";
import { AppendStore } from "./append-store.ts";
import {
  AppendError,
  type WriterRequest,
  type WriterResponse,
} from "./append-types.ts";

const MAX_REQUEST_BYTES = 1 * 1_024 * 1_024;

function argument(name: string): string {
  const index = process.argv.indexOf(name);
  const value = index >= 0 ? process.argv[index + 1] : undefined;
  if (!value) throw new Error(`missing required argument ${name}`);
  return value;
}

function atomicWrite(path: string, response: WriterResponse): void {
  const temporaryPath = `${path}.${process.pid}.tmp`;
  writeFileSync(temporaryPath, `${JSON.stringify(response)}\n`, { flag: "wx" });
  renameSync(temporaryPath, path);
}

const databasePath = argument("--db");
const endpointPath = argument("--endpoint");
const requestsPath = join(endpointPath, "requests");
const responsesPath = join(endpointPath, "responses");
mkdirSync(requestsPath, { recursive: true });
mkdirSync(responsesPath, { recursive: true });
const store = new AppendStore(databasePath);

let closing = false;
let processing = false;
async function processRequests(): Promise<void> {
  if (closing || processing) return;
  processing = true;
  try {
    const requestFiles = readdirSync(requestsPath)
      .filter((name) => /^[0-9a-f-]{36}\.json$/i.test(name))
      .sort();
    for (const name of requestFiles) {
      if (closing) break;
      const requestPath = join(requestsPath, name);
      let request: WriterRequest | undefined;
      try {
        if (statSync(requestPath).size > MAX_REQUEST_BYTES) {
          throw new AppendError("INVALID_COMMAND", "request exceeds size limit");
        }
        const requestText = readFileSync(requestPath, "utf8");
        // Claim before execution. A crash after this point yields no ack, so the
        // caller retries the same collision-safe idempotency key.
        rmSync(requestPath);
        request = JSON.parse(requestText) as WriterRequest;
        if (!request.request_id || !request.operation) {
          throw new Error("missing request fields");
        }
        const result =
          request.operation === "health"
            ? { status: "ok" as const }
            : store.append(request.command);
        atomicWrite(join(responsesPath, name), {
          request_id: request.request_id,
          ok: true,
          result,
        });
      } catch (error) {
        rmSync(requestPath, { force: true });
        const appendError =
          error instanceof AppendError
            ? error
            : new AppendError("INVALID_COMMAND", "invalid writer request", error);
        const requestId = request?.request_id ?? basename(name, ".json");
        atomicWrite(join(responsesPath, name), {
          request_id: requestId,
          ok: false,
          error: { code: appendError.code, message: appendError.message },
        });
      }
    }
  } finally {
    processing = false;
  }
}

const poll = setInterval(() => void processRequests(), 5);
void processRequests();

function close(): void {
  if (closing) return;
  closing = true;
  clearInterval(poll);
  store.close();
  process.exit(0);
}

process.on("SIGINT", close);
process.on("SIGTERM", close);
