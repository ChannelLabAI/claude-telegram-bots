import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import {
  AppendError,
  type AppendCommand,
  type AppendResult,
  type WriterRequest,
  type WriterResponse,
} from "./append-types.ts";

const MAX_RESPONSE_BYTES = 2 * 1_024 * 1_024;

export class EventWriterClient {
  constructor(
    readonly endpointPath: string,
    readonly timeoutMs = 5_000,
  ) {}

  async #request(request: WriterRequest): Promise<unknown> {
    const requestsPath = join(this.endpointPath, "requests");
    const responsesPath = join(this.endpointPath, "responses");
    mkdirSync(requestsPath, { recursive: true });
    mkdirSync(responsesPath, { recursive: true });
    const requestPath = join(requestsPath, `${request.request_id}.json`);
    const temporaryPath = `${requestPath}.${process.pid}.tmp`;
    const responsePath = join(responsesPath, `${request.request_id}.json`);
    writeFileSync(temporaryPath, `${JSON.stringify(request)}\n`, { flag: "wx" });
    renameSync(temporaryPath, requestPath);

    const deadline = Date.now() + this.timeoutMs;
    while (Date.now() < deadline) {
      if (!existsSync(responsePath)) {
        await Bun.sleep(10);
        continue;
      }
      const responseText = readFileSync(responsePath, "utf8");
      rmSync(responsePath, { force: true });
      if (responseText.length > MAX_RESPONSE_BYTES) {
        throw new AppendError("UNAVAILABLE", "event writer response is too large");
      }
      const response = JSON.parse(responseText) as WriterResponse;
      if (response.request_id !== request.request_id) {
        throw new AppendError("UNAVAILABLE", "event writer response ID mismatch");
      }
      if (!response.ok) {
        throw new AppendError(
          response.error.code as AppendError["code"],
          response.error.message,
        );
      }
      return response.result;
    }
    // The writer atomically claims by unlinking a request before its transaction.
    // Removing an unclaimed request is safe; a claimed request may be retried with
    // the same idempotency key after the caller receives UNAVAILABLE.
    rmSync(requestPath, { force: true });
    throw new AppendError("UNAVAILABLE", "event writer request timed out");
  }

  async health(): Promise<Readonly<{ status: "ok" }>> {
    return (await this.#request({
      request_id: randomUUID(),
      operation: "health",
    })) as Readonly<{ status: "ok" }>;
  }

  async append(command: AppendCommand): Promise<AppendResult> {
    return (await this.#request({
      request_id: randomUUID(),
      operation: "append",
      command,
    })) as AppendResult;
  }
}
