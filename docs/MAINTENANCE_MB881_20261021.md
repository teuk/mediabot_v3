# MB881 — The shared IRC output boundary

Base: `snap_mediabot_v3_teuk_20261021_145530.zip`, after MB880,
`3.6dev-20261021_125510`. This round moves the existing output implementation
under IRC while preserving its policies and historical integration points.

## Responsibilities

| Module | Role |
| --- | --- |
| `IRC::Output` | Public `privmsg`, `action`, `notice` functions for other modules. |
| `IRC::Sender` | Internal implementation of the three existing send functions. No exports. |
| `IRC::DeferredOutput` | Internal thirty-item AntiFlood queue and two-second drain. No exports. |
| `IRC::PacedOutput` | Existing explicit PRIVMSG/NOTICE pacing, now using Output. |
| `IRC::Text`, `TextBudget`, `Target`, `CaseMapping`, `Presentation` | The previously extracted text, wire, routing and presentation contracts. |

Use the public facade from a normal parent-side command:

```perl
use Mediabot::IRC::Output qw(privmsg action notice);

privmsg($bot, $channel, $text);
action($bot, $channel, $action_text);
notice($bot, $nick, $private_text);
```

`privmsg` also forwards the existing fourth argument unchanged:

```perl
privmsg($bot, $channel, $text, {no_defer => 1});
```

This preserves the historical immediate-rejection behavior of contextual
replies during AntiFlood. It is not a new expiry mechanism or a delivery
acknowledgement protocol. PRIVMSG keeps its existing accepted/deferred result;
ACTION and NOTICE keep their own historical return conventions.

## The forwarding boundary matters

An imported or fully qualified Output call resolves the corresponding
`Mediabot::Helpers::botPrivmsg`, `botAction` or `botNotice` at call time.
Helpers retains those exported functions as wrappers to Sender. Existing
aliases, bot methods and worker collection therefore retain their original
interception points. The new API does not cache a reference to a real sender
that would bypass a later worker override.

Sender is an internal implementation owner. It does not export its methods;
feature modules should call Output or their existing Helpers/Context interface.
The policy hooks for chansets, AntiFlood, history and console diagnostics
continue to resolve through Helpers. The same is true of text/classification
hooks, preserving existing override points during extraction. This is a
bot-integrated sender, not a standalone pure transport or a new policy engine.

PacedOutput uses the public Output facade for both batch sends and help
notices. Its delays, batching, cleanup, state keys and fallback rules remain
unchanged. DeferredOutput remains a separate queue, with the same state keys
and dynamic Helpers arm/drain/send callbacks as before.

## Preserved behavior

- The three sender bodies are copied without rewriting them. PRIVMSG and
  ACTION retain their own NoColors, AntiFlood and badword paths; NOTICE keeps
  its distinct behavior. They are not forced into one generalized algorithm.
- Text is normalized at the same point before filters, logs and history.
  Byte splitting, encoded buffers and CTCP ACTION envelopes are unchanged.
- Badword cache keys, TTL, queries, bound parameters, statement cleanup and
  existing DB-failure behavior remain unchanged. No SQL statement or schema
  is changed.
- Private service credentials remain present in the intended wire payload
  and masked in every diagnostic copy. Rejected channel output cannot claim
  LIVE output or create accepted conversation history.
- Metrics retain their existing sender-specific conventions. The refactor
  does not add metrics to ACTION or redefine return values.
- AntiFlood still defers ordinary output, rejects `no_defer` PRIVMSG, caps
  queued items at thirty per exact target key, and drains one item per timer.
  A reblocked item returns to the head. Delivery re-enters the ordinary
  sender and rechecks current filters and channel settings.
- Missing-loop behavior, overflow diagnostics, armed flags and two-second
  delays are preserved. The legacy arm and drain hook addresses remain live.
- Worker collection/replay, RSS durable acknowledgement, Hailo/Spark expiry,
  conversation state and specialized pacing machines are not redesigned.

## Audit and tests

The IRC sanitizer invariant now follows the actual ownership chain:
Helpers forwarding, all three Sender normalization calls, the Sender/Helpers
normalizer bridges and the TextBudget implementation. Unrelated newline
handling elsewhere in Helpers cannot hide a disconnected output owner.
The audit still reports 37 invariants.

Three new offline regressions exercise actual sender code with controlled IO
and policy seams, fresh queries and cache reuse, colors, Unicode and encoded
buffers, private redaction, DB failures, metrics, guards, no_defer, worker
capture, actual deferred drains, reblocking, caps and legacy callbacks.
The audit is also executed against partial source fixtures with owners or
links removed and NUL normalization disabled. Only the relevant invariant is
assessed in these deliberately incomplete fixtures.

Historical source checks follow Sender while their runtime assertions and
unrelated Helpers checks remain. The isolated pacing fixture now declares
its Helpers stub as loaded, because the public facade correctly requires its
runtime dependency. It continues to execute the real pacing body.

Before/after comparisons run source and candidate in separate Perl processes.
Their sampled values, flags, wire payloads, timer traces, metrics, logs,
warnings and errors match. This evidence complements the full suite; it
cannot prove equivalence for every possible input. Full results and local
environment limitations are recorded in the package's `QUALIFICATION.md`.

No migration, private configuration, VERSION, service or test runner change
is included. Installation performs no commit, push or bot restart.
