# MB1055 — Fullop operator batches with a native wire budget

Date: 2026-11-01 (Europe/Paris)

## Defect

Fullop's `_send_op_batches` previously split targets only by the server's
advertised MODES count. A valid count does not imply a valid IRC line length:
twenty thirty-byte nicknames already exceed 512 bytes on an ordinary channel.
Longer channel names further reduce the room available for targets. Overlong
commands can leave an op sweep incomplete even though every nickname was
included in the module's submitted-target count.

## Implementation

Build candidate op batches with the existing `Protocol::IRC::Message`
serializer used by the native transport. Count the complete line plus CRLF
with the shared `_irc_wire_bytes` helper. A batch is sent before adding a
target that would exceed either MODES or 512 bytes. Exactly 512 bytes fits.
This also follows the serializer's trailing-argument framing, rather than
maintaining a second estimate of that syntax.

Nicknames remain whole and in their original order. The existing filter and
IRC case-mapping deduplication run before packing. Short-name batches remain
byte-for-byte identical. If even one target cannot fit on its own, skip that
target, emit a fixed bounded diagnostic and continue packing its neighbors.
Do not truncate a nickname into a different identity. Return the count of
targets submitted in MODE commands, excluding skipped entries. Submission is
not a server acknowledgement and does not prove that +o was applied.

The conservative 512-byte limit is not configurable and is not raised by
server extensions. The existing send path, moderation inverses, persistent
ban handling, authentication, service authority and enabled/banned guards are
unchanged. This patch does not validate or rewrite NAMES identities or alter
their encoding policy.

## Regression evidence

Case `1428_mb1055_fullop_mode_wire_budget.t` exercises the real Fullop
entry points and `Protocol::IRC::send_message`; only `write` is replaced by
a local sink. Captured native wire lines are decoded with the native IRC
message parser to check complete target identities and order. There is no
IRC connection, database, HTTP request or service operation.

Thirty-three assertions cover long ASCII names, ordinary thirty-byte names,
raw UTF-8 bytes and channel framing; exact 512-byte and one-byte-over cases;
native trailing-argument syntax; MODES=3; normal joins; RFC1459 and ASCII
deduplication; empty/invalid entries; impossible singletons and bounded
diagnostics; disabled Fullop, banned joins and warning-free execution.
Eleven assertions fail on the untouched runtime; all pass after correction.
Existing Fullop policy, privilege and Cronos tests remain unmodified.

## Operator validation

Apply the supplied patch to the matching snapshot, then run the full native
suite with `--progress`, security/startup audits, generated command inventory
and whitespace checks. A fully passing suite on teuk is required before the
operator script restarts `mediabot@dev.service` and checks a new positive PID
stable for ten seconds. Process stability alone does not prove IRC reconnect.
The installed interactive `commit.sh --skip-preflight` handles commit/push and
the next native 3.8dev VERSION. Do not manually edit VERSION.

Scope: Fullop, CHANGELOG, this note and one new native test. No historical test,
project README, schema, configuration, production, radio or YouTube change.
Detailed local results and environment limits are in the package's
QUALIFICATION.md. No private commit helper is distributed.
