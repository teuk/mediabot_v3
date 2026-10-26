# MB970 — Native factoid learn identity

## Problem

Resolving a Mediabot user by hostmask can return a recognized account whose
authentication state is false. Native `learn` previously stored that object's
id as `FACTOID.created_by` without checking authentication. The subsequent
community-achievement query also received this unverified account identity.

This misattributed newly created facts and could lock their anonymous creator
out of `forget`: MB966 correctly requires authentication for account-owned
facts, whereas anonymous facts retain the existing display-nick ownership rule.
The API v3 factoid service already distinguishes authenticated authors from
anonymous callers.

## Change

Native `learn` binds an account id only after confirming authentication and a
positive numeric id. Otherwise it binds SQL NULL, keeping the current IRC nick
in `created_by_nick`. The existing contribution check receives that same id or
NULL. Public anonymous learning remains available.

The existing UPSERT still changes only value and update time. It retains the
original author id, display nick, row id and creation time. Historical rows are
not rewritten: this correction applies when attributing subsequent commands.
No schema, permissions, configuration or plugin activation changes are needed.

## Regression coverage

`t/cases/1346_mb970_factoid_learn_identity.t` exercises CommunityState,
UserCommands and the native Mediabot facade with real Context and User objects.
SQLite runs with actual foreign keys under both DBI error modes. Only the
MySQL UPSERT syntax is translated to SQLite's equivalent in the test driver.

Coverage includes guests, recognized logged-out users, authenticated accounts,
invalid/missing ids, stored attribution, caller display nicks, confirmation,
metrics, subsequent native deletion, author-preserving updates and another
channel's sentinel data. The existing achievement method executes its actual
SQL queries; only progress persistence and award thresholds are isolated.
Fresh native and API v3 writes are compared for anonymous/authenticated parity.

```sh
perl t/test_commands.pl --filter 'factoid|community_achievements|mb970|module_structure' --progress
perl t/test_commands.pl --progress
perl tools/security_audit.pl --quiet
perl tools/startup_integrity_check.pl --quiet
```
