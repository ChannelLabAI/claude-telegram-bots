# Event-layer operations runbooks

No procedure below authorizes a production restart or deployment. Anya is the
primary operator; 老兔 is the named backup; Bella approval remains the release
gate.

## Disk pressure

Keep the writer fail-closed below either stop threshold. Preserve the database,
WAL, manifests, and last verified projection. Recover space outside those
artifacts, re-run startup validation and a clean checkpoint, then let the
authorized operator reopen traffic.

## Database corruption

Do not repair the only copy in place. Keep read-only degraded mode, verify the
projection snapshot checksum and authorization authority, select the newest
checksummed backup, and follow restore-and-replay in a disposable directory.

## Restore and replay

Verify encrypted bytes against the manifest, decrypt only into a restricted
disposable directory, run `integrity_check`, verify schema and global high-water,
then replay all events into an empty projection target. Retain the timed evidence.
The authorized operator promotes a restored database only after Bella's gate.

## Stuck WAL

Stop new traffic, identify readers holding the WAL, and run a bounded checkpoint.
Do not copy the live database files. A failed or 60-second checkpoint keeps the
service degraded and pages Anya.

## Append or lock latency

Inspect the 15-minute percentile window, writer CPU/I/O, transaction length, and
concurrent callers. A single two-second lock wait stops writes. Capacity changes
require measured evidence and a reviewed ADR.

## Projection drift

Keep the last verified projection for stale-labelled, currently authorized
reads. Rebuild from global sequence one into an empty target and compare the
checkpoint. Never use a projection as authorization enforcement.

## Poison event

Record the failing event ID and consumer checkpoint without payload content.
Pause only the affected consumer, preserve deterministic replay order, and use
an audited repair or schema upcaster before resuming.

## Credential revoke

Fail all degraded reads when the strong authorization authority or revocation
watermark cannot be checked. Rotate credentials through the operator process and
prove a current authorization decision before reopening reads.

## Roster expiry

Block W1 traffic. Anna confirms the accountable owner, Anya or an audited
replacement confirms primary coverage, 老兔 or an audited replacement confirms
backup coverage, and Bella confirms the QA gate. Update the dated machine roster.
