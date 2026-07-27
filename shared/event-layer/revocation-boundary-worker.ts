#!/usr/bin/env bun
// Fixture subprocess used to prove that the identity-side transaction
// boundaries survive a real process death. Production callers use the same
// IdentityRevocationStore and RevocationSynchronizer methods.
import { EventWriterClient } from "./src/append-client.ts";
import { IdentityRevocationStore, RevocationSynchronizer } from "./src/revocation.ts";

function argument(name: string): string {
  const index = process.argv.indexOf(name);
  const value = index >= 0 ? process.argv[index + 1] : undefined;
  if (!value) throw new Error(`missing ${name}`);
  return value;
}

const action = argument("--action");
const identityPath = argument("--identity-db");
const principalId = argument("--principal");
const revocationId = argument("--revocation");
const epoch = Number(argument("--epoch"));
const identity = new IdentityRevocationStore(identityPath);

try {
  if (action === "create") {
    identity.createIntent(principalId, revocationId, epoch);
  } else if (action === "reconcile") {
    const endpoint = argument("--endpoint");
    const workspace = argument("--workspace");
    const intent = identity.intent(revocationId);
    if (!intent) throw new Error("missing intent");
    const outcome = await new RevocationSynchronizer(
      identity,
      new EventWriterClient(endpoint, 1_000),
    ).reconcile(workspace, intent);
    process.stdout.write(`${JSON.stringify(outcome)}\n`);
  } else {
    throw new Error(`unknown action ${action}`);
  }
} finally {
  identity.close();
}
