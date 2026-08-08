# Customer environment phase 1

This is a new customer-only release path. It does not call or modify the
existing `provision-customer-env.sh` v1 path, does not provision a VM, and does
not start or restart any service.

The builder reads only `customer-source-allowlist.txt`, generates the complete
`MVP_*` manifest from actual source references, produces a required-value
template, builds an independent customer UI, compiles the server and preflight,
sanitizes production-only identities and paths from the bundled server, scans
both browser and server artifacts, and rejects any release entry outside
`customer-distribution-allowlist.txt`.
The runtime preflight accepts no inherited `MVP_*` values: the systemd service
passes two root-owned env files to the validator/launcher, which launches the
server with a clean environment. Both `ExecStartPre` and `ExecStart` validate.

Production safety comes from path separation. Existing production startup does
not set `CHANNELLAB_DEPLOYMENT=customer`, so the new server bootstrap validator
is dormant there. The customer unit always sets customer mode indirectly
through the clean launcher. Deployment and the required post-apply production
active/HTTP check remain an authorized-maintainer gate after review.

The distribution exact-set excludes the `.claude-bots` repository, task queue,
team memory, `shared/blocks`, `seabed`, Ocean vault, MemOcean/Radar databases,
bot workspaces, relay, projects, logs, source maps, credentials and source
checkout. Customer state belongs only below `/var/lib/channellab-mvp`; release
code is below `/opt/channellab-mvp` and root-owned configuration below
`/etc/channellab-mvp`.

Run the isolated fixture with a reviewed MVP source tree:

```sh
bash shared/customer-env/phase1/phase1-fixture.sh /path/to/reviewed/mvp
```
