# MB1012 — Dynamic replies survive statistics failures

## Reproduced defect

`mbDbCommand` first loads and renders an active dynamic command, then increments
its hit counter before sending the result. The existing comment explicitly
states that a statistics outage must not suppress a valid response. False
prepare/execute results already allowed delivery, but exceptions did not.

A DBI exception during the increment, a failure while finishing its statement
or an exception from failure logging escaped before the message/action was
sent. A lost acknowledgement could even leave the hit already incremented
while suppressing the response.

## Correction

Contain the single existing `UPDATE PUBLIC_COMMANDS SET hits=hits+1` attempt in
an `eval`. Capture that outcome before best-effort statement cleanup. On failure,
attempt only a fixed operational diagnostic, without publishing driver exception
text, and continue to the existing response path. Failure logging cannot escape.

Never retry an uncertain increment: the write may already have happened. Keep
the existing atomic SQL and bindings. A valid DBI zero-row result remains allowed,
including when the selected row is deleted concurrently. No transaction is
started, committed or rolled back by this change.

The command must still have been read and rendered successfully. Missing and
held commands retain their existing return behavior. Invalid stored targets or
templates remain handled without output or a hit update. Unicode command-name
normalization, arguments, destination and PRIVMSG/ACTION selection are unchanged.

Only the statistics block inside `Mediabot/DBCommands.pm::mbDbCommand` changes at
runtime. No schema, configuration, dependency or other feature is modified.

## Regression evidence

`t/cases/1387_mb1012_dynamic_hit_failures.t` executes the native dynamic-command
dispatcher and real template rendering against SQLite, with faults limited to
the hit writer, cleanup or failure logger. Seven assertions cover:

- Prepare and execute exceptions/false results for messages and actions.
- A real increment followed by a simulated lost acknowledgement: one response,
  one increment attempt and no double counting.
- Cleanup failure after a confirmed increment, and failure-logger exceptions.
- Normal atomic increments, a concurrent row deletion and another command's
  untouched counter.
- Missing/held commands and invalid targets/templates, with no writer call.

The test checks output, return values, database state, exact update attempts and
bindings, cleanup, warnings and bounded failure diagnostics. Five assertions
fail before correction; all seven pass afterwards. No existing tests are changed
or removed. No external SQL server or IRC connection is used.

```bash
perl t/test_commands.pl --filter 'dynamic|1387_mb1012|module_structure' --progress
perl t/test_commands.pl --progress
perl tools/security_audit.pl --quiet
perl tools/startup_integrity_check.pl --quiet
perl tools/mb_architecture_inventory.pl --check docs/generated/COMMAND_INVENTORY.md
```

The delivery README records the actual full-suite result and comparisons with
the unchanged snapshot. The supplied procedure runs the complete suite before
restarting only `mediabot@dev.service`, then calls the native `commit.sh` flow.
No remote service, commit, push or production deployment was performed during
this local qualification.
