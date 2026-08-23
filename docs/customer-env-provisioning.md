# Customer MVP environment provisioning v1

Each customer gets a separate systemd user unit, TCP port, mutable data root,
and vault root. All instances share the reviewed MVP code checkout so an
upgrade is applied once. `MVP_DATA_DIR` owns mutable MVP state; when it is
unset, the server falls back to `MVP_DIR`, preserving the existing instance.

v1 exposes `--target` as part of the interface and accepts only `local`.
Remote/VM deployment must add a target adapter later, not change the customer
parameter contract.

## Prerequisites and safety boundary

Apply both reviewed ba17 patches first: the MVP data-directory patch and the
root provisioning patch. Do not run the provisioner from an unreviewed branch.
The provisioner never addresses `mvp-server.service`, rejects port 8090, refuses
to overwrite drifted unit/config files, and will only purge a data directory
that contains its exact customer marker.

Customer units point every product-owned mutable/read-model source at the
customer data root. Their systemd/FATQ writer binaries fail closed because
agent/control-plane tenancy is explicitly outside v1. `MVP_DIR` remains the
shared code root, and `MVP_OCEAN_SEARCH_ROOT` / `MVP_OCEAN_WRITE_ROOT` are the
customer's vault root.

## Provision NOXCAT

Choose an approved allowlist before running this. The first host rollout uses
port 8091 unless operations selects another unused non-8090 port.

```bash
shared/bin/provision-customer-env.sh provision \
  --target local \
  --customer NOXCAT \
  --port 8091 \
  --emails 'approved-owner@example.com,approved-ops@example.com' \
  --data-dir /home/oldrabbit/.claude-bots/customers/noxcat/mvp-data \
  --vault-root '/home/oldrabbit/Documents/Obsidian Vault/Ocean/業務流/NOXCAT' \
  --code-dir /home/oldrabbit/.claude-bots/mvp
```

An exact rerun is idempotent: it does not create another unit or overwrite
customer data. Parameter drift fails closed; inspect and deliberately uninstall
before changing an installed instance's configuration.

## Acceptance run for a customer

The retired NOXCAT-specific acceptance wrapper is no longer part of the
repository. After Bella approval and host apply, use the rollout task's
reviewed host checklist and attach its evidence to that task. Keep the checks
customer-specific and verify production isolation, HTTP response, path
isolation, idempotency, uninstall, and final reprovision before closeout.

## List instances

```bash
shared/bin/provision-customer-env.sh list --target local
systemctl --user list-units 'mvp-customer-*.service'
```

The first command reads provisioner metadata and shows customer, unit, port,
and data root. The second shows current runtime state.

## Uninstall

Stop the unit and remove its unit/config while preserving data (default):

```bash
shared/bin/provision-customer-env.sh uninstall --target local --customer NOXCAT
```

Permanently delete the marker-owned customer data as well:

```bash
shared/bin/provision-customer-env.sh uninstall --target local --customer NOXCAT --purge-data
```

The purge form is destructive and should only follow a verified backup or an
explicit decision that the customer data is disposable.

## Upgrade all instances

1. Merge and apply the reviewed MVP code patch once to the shared `MVP_DIR`.
2. Run the project build/fixtures before any restart.
3. After approval, restart customer units one at a time and check their port:

```bash
while read -r unit; do
  systemctl --user restart "$unit"
  systemctl --user is-active --quiet "$unit" || exit 1
done < <(systemctl --user list-unit-files 'mvp-customer-*.service' --no-legend | awk '{print $1}')
```

The existing `mvp-server.service` remains a separate rollout target and must
follow its own reviewed restart procedure.

## Mutable read/write points moved to MVP_DATA_DIR

- `users.db`
- `thread-map-v0.json` unless `MVP_THREAD_MAP` is explicitly set
- `thread-map-v1.db` unless `MVP_THREAD_MAP_DB` is explicitly set
- `.internal-write-secret` unless its explicit file variable is set
- `audit.log`
- `knowledge-write.audit.jsonl` unless `MVP_KNOWLEDGE_AUDIT` is explicitly set

`app.html` intentionally stays under `MVP_DIR`; it is shared application code,
not customer data. The resolver fixture prints both unset fallback paths and an
explicit NOXCAT-style data-root resolution for direct comparison.
