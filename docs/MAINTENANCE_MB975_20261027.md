# MB975 — Restore native quote-add alias dispatch

## Reproduced defect

The native public registry handler for `quote add` called `mbQuoteAdd` with
four positional arguments, but that function expects the bot, message,
authenticated user id, account handle, IRC nick, channel, then quote text.
The adapter also removed `add` from the caller's original context arguments.
Consequently a normal `!quote add <text>` did not insert the quote and the
syntax response had no valid recipient. The equivalent `!q add <text>`
already used the context-aware `mbQuotes_ctx` dispatcher correctly.

This also affected native fallback when the official `quotes-v3` package was
disabled, channel-off, observing, or unloaded. Its channel-on implementation
already had a working `quote add` path.

## Change

The registry `quote add` branch now delegates its complete original context
to `mbQuotes_ctx`. That dispatcher resolves the user, authenticated account
or anonymous author, caller nick, message, channel and text using the same
path as `q add`. The adapter no longer consumes the original arguments.

The change is limited to the `add` branch. Existing duplicate handling,
512-character limit, syntax errors, database lookup protection and native
contribution hook remain owned by the existing handlers. No SQL schema,
configuration, grants or plugin activation changes are required.

## Regression coverage

`t/cases/1351_mb975_quote_add_registry_context.t` constructs the real bot and
command registry, uses actual contexts and users, and observes real persisted
SQLite rows through a second database connection with foreign keys enabled.
It covers native `q` and `quote`, case-insensitive `add`, unknown/recognized
logged-out/authenticated callers, Unicode multi-argument text, persisted ids,
author attribution, duplicate detection, contribution accounting, argument
preservation, syntax and length errors, both DBI error modes and a failing
duplicate lookup through the alias.

It also loads the official `quotes-v3` package through the actual runtime,
exercises disabled/off/observe/on modes and unload, and verifies one stored
quote and one public acknowledgement per command. Unload restores the exact
native registry handler reference.

The regression has 568 assertions: 194 fail against the supplied snapshot;
all pass with the fix. The quote/module targeted suite passes 3,803 assertions
across 36 files. Full-suite and audit results are recorded in the delivery
README. Deployment must pass the full suite on teuk before restarting dev and
committing through the native script.
