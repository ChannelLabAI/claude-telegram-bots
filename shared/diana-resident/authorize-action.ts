#!/usr/bin/env bun
import { authorize } from "./authorization.ts";
const action = process.argv[2] ?? "";
const result = authorize({ action, operationClass: "recovery" });
if (result.decision !== "ALLOW") { process.stderr.write(`DENY action=${action} reason=${result.reason}\n`); process.exit(2); }
process.stdout.write(`ALLOW action=${action} reason=${result.reason}\n`);
