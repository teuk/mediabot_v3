# MB1050 — Retry expired bans after absence

The expiry scheduler used to mark a persistent ban removed even when Mediabot
was not in the channel and sent no `MODE -b`. The IRC ban could therefore remain
on the server while its SQL row was retired, preventing all subsequent retries.
An old nickname cache could also allow this cleanup while IRC was disconnected.

`process_expired_channel_bans` now requires connected IRC state before reading
expired rows. For each row, absence from the channel defers both the IRC command
and SQL update. Other joined channels still progress in the same tick. Once the
bot rejoins and its nickname list confirms presence, the next tick dispatches
the original mask and retains the normal removal audit fields. Deferred rows
use a debug message; the normal expiration message follows the presence check.

The existing command-before-SQL order is retained. A thrown dispatch error or
SQL write failure leaves the row eligible for retry. Successful completion and
the expiration metric additionally require a positive affected-row count, not
DBI's truthy `0E0` value. Permanent, future and already removed bans are unchanged.

This is not an IRC acknowledgement protocol: the current implementation still
uses local command dispatch as its IRC boundary. Server rejection, operator
privilege loss or a disconnect after dispatch are not newly confirmed here.
Rows already incorrectly retired by older versions are not reactivated.

## Validation

`1423_mb1050_ban_expiry_retry.t` exercises the native scheduler and ChannelBan
repository against an in-memory SQLite database. Only IRC, logging and metrics
are local sinks. Its thirty assertions cover absence, later joins, case variants
already supported by the nickname helper, stale nick lists while disconnected,
unavailable connection state, exact masks/channels, update ordering, ordinary
audit data, independent channels, transport and SQL recovery, truthy zero rows,
repeat ticks and preservation of unrelated bans. Twenty fail on the unchanged
public runtime, ten pass. All thirty pass after correction.

The old `69_channelban_db_safety.t` IRC fixture explicitly reports its connected
state so its existing native reconnect-and-expire scenario remains meaningful.
No assertion is removed or disabled. The delivery package records the targeted
and full-suite results, baseline environmental failures and public patch reversal.

## Operator flow

The package verifies checksums and applies the patch idempotently. It requires
the full visible `perl t/test_commands.pl --progress`, security audit, startup
integrity, generated command inventory and whitespace checks before restarting
only `mediabot@dev.service`. It then requires a new positive PID stable for ten
seconds before invoking the installed interactive `commit.sh --skip-preflight`.
VERSION stays untouched by the patch; the native helper continues 3.8dev.
No production service, SQL migration, private configuration or dependency is
changed, and the private commit helper is not part of the package.
