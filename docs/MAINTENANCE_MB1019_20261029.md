# MB1019 — Keep the first plugin store attempt authoritative after failure

## Reproduced problem

The script action contract permits one store per invocation, with the first
document winning. `ScriptActionRunner::apply_actions` set its duplicate guard
only after the injected storage sink reported success. A false return or an
exception therefore allowed a later store to call the sink again.

The document that reached storage depended on the first attempt's I/O result.
A genuine native disk-open failure followed by filesystem recovery caused the
second document to replace the previous state, contrary to the first-store
rule. If a sink had published the first document before losing its receipt,
the second attempt could replace that actual publication too.

## Change

Reserve the invocation's one storage attempt immediately before calling the
sink, after the existing apply/gate/sink/validation checks. Preserve the first
failure and report subsequent stores using the existing duplicate diagnostic.
Do not claim success or retry an uncertain result.

Only this duplicate guard changes at runtime, in
`Mediabot/ScriptActionRunner.pm`. The counter remains local to one invocation:
a new invocation retains its own attempt. Successful first stores, storage
format, paths, limits and native metrics are unchanged. No schema, dependency,
configuration or capability changes.

Unrelated authorized actions continue under the existing action-loop policy;
this is not a transaction over all actions and does not roll back a published
document after an uncertain receipt. ScriptRunner and API v3 repository commit
semantics are not replaced by this per-script-action guard.

## Regression and qualification

Eight focused assertions are added in
`t/cases/1394_mb1019_single_store_attempt.t`. Five fail on the supplied unchanged
snapshot and all eight pass after correction. Existing tests are unchanged.

The cases exercise the actual JSON action planner/applier and native
PluginManager file storage, including:

- Successful first store, exact context, duplicate rejection and native metrics.
- False and throwing first receipts without promotion of a later document.
- Real atomic publication followed by an injected uncertain acknowledgement,
  retaining the first document without a second publication.
- Real native open failure, induced by a directory at the private temporary
  filename, then removal of that obstacle before the next action. This also
  reproduces reliably when the tests run as root, without permission guessing.
- A fresh budget in the next invocation; dry mode, gates and invalid plans.
- Continued authorized log/reply actions, original error retention and no warning.

All fixtures are temporary and isolated. No database, live plugin, IRC server
or private configuration is contacted. The uncertain-receipt case is a fault
injected at the public sink boundary, not a claim that the native disk writer
currently loses its own acknowledgement after publication.

Qualification commands:

```bash
perl t/test_commands.pl --filter '1394_mb1019|script.*action|scriptaction|plugin.*stor|plugin_kv|mb60[1-5]|module_structure' --progress
perl t/test_commands.pl --progress
perl tools/security_audit.pl --quiet
perl tools/startup_integrity_check.pl --quiet
perl tools/mb_architecture_inventory.pl --check docs/generated/COMMAND_INVENTORY.md
```

The delivery README records actual results and any failures also reproduced on
the unchanged snapshot here. Deployment stops at the first failed check,
restarts dev only after success and invokes native `commit.sh` for confirmation,
versioning, commit and push. No remote deployment or commit is claimed by these
offline checks.
