# MB965 — Personal note storage consistency

## Reproduced failures

The native personal-note commands could report successful storage while SQL
had failed. A failed INSERT still appended a memory-only note with an invented
ordinal id. That note disappeared at restart, and its fallback id was not the
database identity required for deletion.

Deletion removed the cached note before executing DELETE, ignored database
errors and announced success regardless. A failed deletion therefore hid the
note until a restart or cache reload made it reappear.

The initial loader also treated failed reads like empty results and could
publish a partial fetch. This let additions bypass the ten-note cap during a
read failure, or made list/export/search report an empty or incomplete result.

## Correction

- Load notes into a temporary array and publish it only after the entire read
  succeeds. A confirmed empty result remains valid. A failed load stops the
  calling operation with a private database-error notice.
- Confirm the INSERT affected one row and returned a positive persistent id
  before appending to the cache or reporting a saved note. Displayed ordinals
  remain list positions, never replacement database ids.
- Execute DELETE before removing the cached entry. SQL errors and a zero-row
  result do not produce a false deletion acknowledgement.
- Mark the user's cache for reconciliation after an unconfirmed write or
  missing row. Preserve its last complete contents, but require a successful
  reload before another note operation can use them. A failed reload does not
  publish partial data or allow a second mutation.

A lost connection can occur after the server commits a write. The error notice
therefore asks the user to check `!notes` before retrying instead of claiming
the write definitely did not happen. A missing insert id uses this same path:
the next successful read recovers the real id of the committed note.

All failures use fixed private notices. Raw database exceptions and note text
are not exposed by those diagnostics. Normal successful acknowledgements,
search ordinals, owner-scoped deletion, Unicode text, the 200-character limit
and the ten-note cap retain their existing behavior.

No SQL schema, existing note rows, credentials or private configuration are
changed by installation. No memory-only success fallback is used when NOTE
storage cannot be confirmed. This does not introduce transactions or attempt
to synchronize otherwise healthy caches between separate bot processes.

## Validation

`1341_mb965_notes_storage_consistency.t` invokes the actual handlers through
CommunityState, UserCommands and the Mediabot facade. Its SQLite fixture uses
DBI RootClass fault injection with RaiseError both enabled and disabled.

The 1,902 assertions cover prepare/execute/fetch failures, partial reads,
affected-row failures, lost write acknowledgements after actual commits,
missing insert identities, failed reconciliation reads, stale cached ids,
healthy save/search/delete, empty reads, Unicode length limits and preservation
of another user's notes. The supplied source fails 825 of these assertions;
the corrected source passes all of them.

```bash
perl t/test_commands.pl --filter 'note|notes|mb456|community_state|mb965|module_structure' --progress
perl t/test_commands.pl --progress
perl tools/security_audit.pl --quiet
perl tools/startup_integrity_check.pl --quiet
```

The tests contact no live SQL or IRC service.
