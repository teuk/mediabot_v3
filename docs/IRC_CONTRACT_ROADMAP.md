# IRC contract roadmap — Eggdrop comparison

Accepted by the maintainer on 2026-11-12. This is the active continuation after
the bounded architecture chapter. Baseline: Mediabot commit
`09ec3c828f376d8d143d298ad28d68923a68c4a1` (MB1255).
Reference: Eggdrop v1.10.2, tag commit
`9c00fe1c183dd733da3dacae8bdbc1ddc887dfdb`. This is a fixed comparison baseline,
not a claim about the newest release or an instruction to copy its implementation.

## Scope and completion

Compare observable guarantees, not feature counts. Account for behavior delegated
to Net::Async::IRC before declaring a Mediabot gap. Do not infer a live incident
from an isolated source discrepancy. No production connection, schema migration
or service restart belongs to the comparison itself.

Each of the five rows below must end with expected behavior, exact source owners,
a reproducible scenario, evidence, and a verdict: covered, partly covered,
reproduced defect, or deliberately out of scope. Close this roadmap when all rows
have a verdict and all selected blocking defects have target-host acceptance.
Record residual risks explicitly. New feature ideas do not extend the exit gate.

| Order | Contract | Evidence to obtain | Current verdict |
| --- | --- | --- | --- |
| 1 | Connection-specific IRC identity | ASCII/RFC1459/strict mappings; capability replacement/removal; reconnect; bot exclusions and authorization consumers; durable-key compatibility | Partly covered. MB1256 fixes one reproduced exclusion mismatch; broader consumers remain to audit. |
| 2 | Trustworthy channel state | JOIN followed by partial NAMES/WHO/MODE; concurrent NICK/PART/KICK; end-of-list; disconnect/rejoin; decisions before synchronization | Not assessed. Presence of handlers is not proof of the contract. |
| 3 | Control traffic under pressure | Actual transport queue ownership, caps, priorities and penalties; saturated previews alongside control commands; stale output after reconnect | Not assessed. Trace Net::Async::IRC as well as Mediabot. |
| 4 | Correct authority over time | Identity changes, host/account changes, explicit revocation, channel/global scopes and queued privileged work | Not assessed. No permission bypass is claimed. |
| 5 | Predictable reload and recovery | Successful/failed reload, callback/timer ownership, persistent versus live state, useful operator diagnosis | Not assessed. Reuse existing lifecycle evidence before adding tests. |

Botnet replication, DCC file transfer and Tcl compatibility are not parity goals.
Radio and YouTube behavior remain regression-sensitive. A useful guarantee may
be implemented differently; an optional Eggdrop feature need not be implemented.

## Reference mechanisms already inspected

- [Eggdrop server queues](https://github.com/eggheads/eggdrop/blob/9c00fe1c183dd733da3dacae8bdbc1ddc887dfdb/src/mod/server.mod/server.c):
  deq_msg distinguishes mode, normal and help queues; calc_penalty accounts for
  commands/network settings. This does not prove Mediabot lacks transport pacing.
- [Eggdrop ISUPPORT](https://github.com/eggheads/eggdrop/blob/9c00fe1c183dd733da3dacae8bdbc1ddc887dfdb/src/mod/server.mod/isupport.c)
  and [channel handling](https://github.com/eggheads/eggdrop/blob/9c00fe1c183dd733da3dacae8bdbc1ddc887dfdb/src/mod/irc.mod/chan.c):
  negotiated mode/prefix handling; got315 synchronizes members and changes a
  pending channel to active. Audit Mediabot's corresponding decisions next.

## MB1256 — Conversational bot exclusions use the connection mapping

Reproduction on the baseline: Spark::Identity identifies Nick{ as configured
Nick[ even under an ASCII connection, whereas ConversationRuntimeState keeps
those identities distinct. This can incorrectly exclude a human from the
conversational path. It is not evidence of a permission escalation.

[Identity](../Mediabot/Spark/Identity.pm) now accepts an optional casemapping and
uses the existing [folding helper](../Mediabot/IRC/CaseMapping.pm). Omitted mappings
retain the historical RFC1459 helper contract for existing external callers.
The two public message decisions in [mediabot.pl](../mediabot.pl) explicitly
supply the current connection mapping through a read-only accessor on
[ConversationRuntimeState](../Mediabot/AI/ConversationRuntimeState.pm).
The existing state already accepts ISUPPORT changes/removal and resets to ASCII
on disconnect. Missing runtime state uses ASCII, not the last connection's rules.
Both BOT_NICKS and WIT_IGNORE_NICKS use this path; ordinary letter-case matching,
input validation and the default Coin exclusion remain intact.

No durable Hailo brain identity, user database key or authorization rule changes.
Hailo-specific exclusions, other hardcoded folds and Fullop capability removal
remain audit candidates, not silently declared fixed by this delivery.

Validation: the five available cases 1004/1049/1063/1236/1304 pass 325 assertions.
Case 1063 covers both live bot and configured exclusions, three mappings,
replacement/removal and reconnect. Existing case 1049 exercises the Wit/Quip
routing block; a small source check verifies both main call sites pass the rule.
Native full-main compilation and case 1358 are blocked locally by missing
Config::Simple; neither is reported as passing. Host syntax, six targeted cases
and one complete suite are mandatory before commit. Host acceptance is pending.

Next: finish row 1's remaining identity consumers and inventory row 2's channel
synchronization authority. Choose the next correction only from demonstrated
behavior, preserving persistent identities and established permissions.
