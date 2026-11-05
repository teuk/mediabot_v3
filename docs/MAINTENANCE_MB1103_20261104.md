# MB1103 — Reject invalid ban durations before persistence

## Fault

parse_duration accepted arbitrarily long numeric inputs before multiplying by
the unit factor. Large digit strings became scientific notation or Inf without
an error. add_ban then replaced any expires_seconds value failing its positive
digits test with undef: SQL NULL means permanent. A nominally timed operation
could therefore be stored and announced as a permanent ban. Direct API callers
could trigger the same conversion with negative, fractional or malformed input.

## Correction and bounded policy

Use a shared decimal-text check before numeric conversion. Temporary bans are
now bounded to 2,147,483,647 whole seconds. This is an application safety limit,
not a claim about the maximum MariaDB INTERVAL or DATETIME range. Operators
wanting permanence must choose it explicitly. Normalize leading zeros, compare
against the unit-specific quotient, then multiply only a known bounded integer.
Bare values remain minutes; m/h/d/w and their case-insensitive forms keep their
labels. Textual permanent aliases and empty/undefined parser input retain their
existing behavior. The parser still refuses bare zero and zero-unit durations.

At the persistence boundary, undefined or integer zero still intentionally mean
permanent. Any other supplied seconds must be a nonnegative ASCII integer in
the supported range; invalid input returns an explicit error before lookup or
INSERT. In particular, references, fractional/negative values, scientific
notation, Inf, NaN, trailing newlines and oversized strings cannot become NULL.
A legacy expires_at without supplied seconds retains its previous fallback.

The INSERT expression stays NOW() + INTERVAL ? SECOND: the SQL session still
owns the expiration clock, and no timestamp is calculated in Perl. Public
ban/kickban/kb already stop on a parser/add error; the real handlers are tested
to issue one notice and no storage, MODE or KICK for an overlarge duration.
The Partyline WHOIS storage path also receives the persistence guard before
its MODE operation. No ban level, mask, permission or expiry-retry policy is
changed, and no existing ban row is rewritten.

## Essential native tests

Reuse case 69's existing real SQLite/DBI child, including its connection owner
and SQL interval adapter. Add one grouped parser check for ordinary values,
leading zeros and the exact last valid minute/hour/day/week counts, followed
by over-limit and 309-digit inputs. Add one grouped storage check in both DBI
RaiseError modes: exact 1/10/600/maximum-second expirations, intentional
permanence, eleven invalid forms and successful use of the same helper after
each refusal. Check rows, expiry binds, SQL dates and warning-free behavior.

Case 09 adds nine real handler refusals across ban/kickban/kb. Existing unit,
permission, level, mask, delegation, reconnect and expiry pipeline tests remain.
Remove six copied normalizer assertions from case 569; two explicitly endorsed
the bad negative/text-to-NULL behavior. Its SQL expression and both caller
wiring checks remain. Remove 32 extracted parser assertions from case 676: cases 06/69 now exercise
that behavior through the real module and its helpers. Keep the independent
Spotify formatter checks. Three grouped checks replace 38 assertions: 35 fewer
assertions without a new test file, child, sleep or runtime dependency.

## Operator workflow

Validate the exact cumulative scope; run targeted checks, the visible full suite
with --progress and security/startup/inventory checks. Restart only the dev,
then require a new positive PID stable ten seconds before interactive commit.sh.
VERSION remains under the native automatic 3.8dev plan. Process stability alone
is not proof of IRC reconnection. No schema or production deployment is included.
