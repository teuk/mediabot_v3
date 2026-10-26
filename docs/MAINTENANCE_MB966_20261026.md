# MB966 — Native factoid deletion identity

## Reproduced failures

The native `!forget` handler checked only `created_by_nick` even when FACTOID
already recorded a numeric account author in `created_by`. Reusing that IRC
nickname could therefore authorize another person to delete the fact. The
actual author could instead be refused after changing their IRC nickname.

The channel-operator fallback also looked up a known account's channel level
without first requiring that account to be authenticated.

After checking ownership, DELETE targeted only the channel and keyword. If
another connection removed and recreated that keyword before DELETE, the
replacement inherited permission granted for the old fact. A zero-row DELETE
still produced a success notice and incremented the deletion counter.

## Correction and compatibility

- When `created_by` is present, authorship requires an authenticated matching
  user id. The display nickname does not confer account ownership.
- When `created_by` is NULL, retain the historical case-insensitive nickname
  ownership rule for anonymous facts. No existing authorship rows are rewritten.
- Require authentication before the existing per-channel operator lookup;
  retain the channel-level threshold of 400 and the requested channel scope.
- Read and validate `id_factoid`, then bind that exact id and channel to DELETE.
  A different row created under the same keyword cannot be deleted by this
  stale authorization. An ordinary value update retaining the original row and
  author keeps the existing ownership semantics.
- Acknowledge and count deletion only when an affected row is confirmed.
  A missing or replaced row instead asks the caller to retry. A failed lookup
  is distinct from an absent fact, and an uncertain write reports that deletion
  could not be confirmed.

All error notices remain private and contain no raw database exceptions.
Commands, feature gating, plugin policies and database schema are unchanged.
The API v3 factoid service is not modified; the corrected native handler also
remains available to its existing saved-handler fallback.

## Validation

`1342_mb966_factoid_forget_identity.t` calls the real handler through
CommunityState, UserCommands and the Mediabot facade, with real Context and
User objects. SQLite executes the author and operator queries and the DELETE.
A second actual connection reproduces removal/replacement after authorization
and before deletion. DBI RootClass injection covers prepare, execute, fetch and
affected-row failures under both RaiseError modes.

The 762 assertions cover nickname reuse, account continuity across nick
changes, logged-out accounts, operator thresholds and channel isolation,
legacy anonymous ownership, NULL display nicknames, concurrent replacements,
confirmed absence, private errors and accurate success counters. The supplied
source fails 216 assertions; the corrected source passes all 762.

The older factoid test fixture now models persistent ids, numeric authors and
affected-row counts so its existing successful and denied operations remain
meaningful against the corrected native SQL.

```bash
perl t/test_commands.pl --filter 'factoid|community_state|mb966|module_structure' --progress
perl t/test_commands.pl --progress
perl tools/security_audit.pl --quiet
perl tools/startup_integrity_check.pl --quiet
```

These tests contact no live SQL server or IRC service. Installation performs
no data migration and changes no private configuration.
