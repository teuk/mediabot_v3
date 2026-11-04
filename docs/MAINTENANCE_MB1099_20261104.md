# MB1099 — Public IRC response timer: !ping

## Usage

In a channel, use the configured command prefix:

```text
<Alice> !ping
<Mediabot> POng ! [1.334s]
```

The native public command needs no login, API key, chanset or database migration.
It also follows the existing bot-nick/initial command triggers. Replies keep the
requested capitalization, one space before `!`, and three decimals in seconds.
There is no artificial delay; a fast response can legitimately show `0.000s`.

## What is measured

A local monotonic clock starts as the IRC PRIVMSG enters the application wrapper.
The final value is rendered after command dispatch, public-command observers,
output AntiFlood admission and the outgoing badword lookup, just before filtering,
history and IRC transport preparation. The original channel target is retained.

This measures Mediabot's local response preparation, including any AntiFlood
queue wait. It does not measure the sender-to-server leg, transport buffering,
server-to-client delivery or a user round trip. No IRC PING probe, CTCP exchange,
external service or blocking sleep is introduced.

## Implementation

- Add `ping` to the authoritative public built-in catalogue, its native handler
  and help. It has no legacy migration fallback. Private command routing is
  unchanged; this feature is the public channel `!ping` command.
- The incoming timestamp is dynamically scoped to the current PRIVMSG. Nested
  messages and exceptions restore the previous value. Direct public dispatch
  callers without an IRC ingress stamp get a new start at dispatcher entry.
- The handler submits a fixed placeholder and a scalar monotonic timestamp.
  The sender renders the fixed ASCII reply after output policy and SQL work;
  its final text goes through the normal badword, history, log and wire paths.
- Deferred output copies only the timestamp, not a Context, IRC message object
  or callback. Reflooding retains that stamp and the queue head. Ordinary
  message/ACTION queue entries keep their historical two-field shape and FIFO.
  The thirty-item cap and timer ownership policy remain unchanged.
- Invalid/reference/oversized timestamps are ignored. A backwards clock cannot
  produce a negative duration, and timing metadata cannot rewrite arbitrary text.

The command respects existing per-channel, per-nick and command-cooldown gates,
NoColors, output AntiFlood and badword filtering. It does not bypass protection
to ensure a reply. VERSION remains under the native 3.8dev commit workflow.

## Verification

Extend the existing native output test, without adding a test file, child
process or real sleep. Four grouped checks cover:

1. The actual incoming wrapper in void/scalar/list contexts, including nested
   messages, exception unwinding and restoration of prior receipt stamps.
2. Native registry and public dispatch on all four channel prefixes, command
   case folding, observer and SQL time, exact output/history, metadata and
   repeated direct calls without stale start times.
3. Deferred/reflooded output, the original timestamp, measured waiting and
   ordinary-message FIFO compatibility.
4. Channel/nick/cooldown/badword admission, filtering of the final measured
   text, invalid timestamps, normal output and nonnegative formatting.

Remove three superseded source-text wrapper checks from MB548: the new native
wrapper check proves their behavior. Update existing catalogue-count expectations
and regenerate the command inventory. Net increase: one assertion for a new
public command; the test-file count is unchanged.
