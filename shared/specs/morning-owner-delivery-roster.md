# Morning owner-delivery roster

`shared/config/morning-owner-delivery-roster.json` is the single operational
roster for the 08:57 morning owner-DM batch.  It contains the bot handle,
gateway state directory, and the vault journal location required by that
batch.

Both consumers read this file directly:

- `shared/bin/morning-todo-all.sh` emits one owner-DM relay per roster entry.
- `shared/scripts/owner-delivery-zero-receipt-alert.ts` expects one gateway
  receipt per roster entry after the grace period.

`shared/team-config.json` remains the authority for each roster bot's owner
mapping and chat ID.  It is deliberately not the delivery roster: a valid
assistant mapping without a vault-backed morning brief must not become a
permanent zero-receipt alert.

To add or remove a morning recipient, make the personnel decision separately,
then change only this roster file.  Do not add the bot to one consumer by
itself.  The current eight entries exactly preserve the pre-alignment morning
recipient set.  `shared/tests/owner-delivery-zero-receipt-alert-test.sh` runs
the producer against this checked-in roster in an isolated HOME and asserts
eight `*-morning-<bot>.json` relays; its negative case corrupts one owner
mapping, verifies seven relays, and proves that the eight-relay assertion
fails.
