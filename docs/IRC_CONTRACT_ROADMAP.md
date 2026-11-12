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
| 1 | Connection-specific IRC identity | ASCII/RFC1459/strict mappings; capability replacement/removal; reconnect; bot exclusions and authorization consumers; durable-key compatibility | Partly covered. MB1256 fixes conversational exclusions; MB1257 fixes Fullop capability withdrawal. MB1258 resets Fullop at transport construction; remaining identity consumers stay open. |
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


## MB1257 — Fullop retires withdrawn capability semantics

Base `381484276e88c3df202fb3703d787e41359efad9` is committed MB1256 and matches
every tracked file of the supplied 2026-11-12 18:03:51 snapshot. Commit presence
does not independently establish the numerical full-host test result or activation.

Reproduced defect: update_isupport removed -KEY from its raw table while keeping
the effective network, folding, prefix, mode grammar and batching fields. After
CASEMAPPING=ascii, PREFIX=(ohv)@%+ and MODES=1 were withdrawn, real op sweeps still
separated RFC-equivalent names into one-op batches and NAMES still stripped %.
This is a local replay of server announcements, not evidence of a live incident.

Correction in [Fullop](../Mediabot/Fullop.pm): withdrawal of an advertised key
restores its constructor fallback: CASEMAPPING=rfc1459, PREFIX=(ov)@+,
CHANMODES=beI,k,l,imnpst and MODES=4. NETWORK returns to the original configured
network (or the empty constructor fallback), not a withdrawn server claim.
These are Mediabot's existing fallbacks, not Eggdrop's numeric defaults.
ConversationRuntimeState's conservative ASCII fallback is intentionally unchanged;
this delivery does not claim that all identity consumers now share one policy.

Withdrawn identity/prefix/mode grammar invalidates the old in-memory mode snapshot
and delegated-ban correlations; old keys and mode categories cannot be reused
under the restored interpretation. NETWORK withdrawal also clears correlations.
Fresh observations rebuild the snapshot. Durable ChannelBan records, user data,
configuration callbacks, exemptions and normal advertised behavior are unchanged.
Unknown capabilities only lose their raw entry. Repeated withdrawal of a key
already absent is inert; re-advertisement becomes effective normally.

Comparative finding: pinned Eggdrop isupport.c has effective default values and
an internal isupport_unset API, but its isupport_parse explicitly logs that wire
-KEY unsetting is unsupported and skips it. Do not report Eggdrop 1.10.2 as passing
this wire-withdrawal contract. The comparison guides questions, not blind parity.

Validation: existing case 1031 extended to 81 native assertions; the baseline
fails 12 of these checks. The seven-case lane 1031/1032/1033/1051/1052/1304/1428
passes 476 assertions, covering policy, privilege boundaries, network-service
exceptions, integration wiring and wire budgets. Full installed-host validation
remains mandatory before commit; no full local suite or live restart is claimed.

Remaining row-1 work: Fullop lifecycle across transport replacement, live mapping
replacement and other identity consumers, especially durable identities. Neither
this withdrawal fix nor MB1256 closes the whole identity contract. Row 2 still
requires a trace of channel readiness and decisions made during partial sync.


## MB1258 — Fullop observations belong to one transport

Base `a16dabbbc5c14d3161a5ebad75131527fb2ea755` is committed MB1257 and matches
every tracked file of the 2026-11-12 18:42:49 snapshot. No numerical target-host
acceptance or running-version claim is inferred from the commit.

Reproduced gap: the main program keeps one Fullop instance while _build_irc creates
a fresh IRC object for reconnect. Old ISUPPORT, MODE snapshots and delegated-ban
correlations survived that replacement. A native policy replay demonstrates that
an old channel key remains available for restoration after a new-server -k *;
old network, prefix, folding and batching observations also remain effective.

[Fullop::reset_connection](../Mediabot/Fullop.pm) now restores the existing
constructor defaults and original configured network, and clears raw ISUPPORT,
channel-mode snapshots and delegated-ban correlations. It retains the policy
callbacks, explicit service masks, durable ChannelBan service and enabled/privileged
checks. It performs no IRC send, database write or configuration mutation.
[The common transport builder](../mediabot.pl) invokes it before constructing or
registering Net::Async::IRC. Initial startup, reconnect and subsequent failed
construction attempts therefore start with fresh Fullop observations.

This is a transport-construction boundary, not a new disconnected moderation
state machine. It does not reject late callbacks from obsolete transports, clear
external NAMES buffers, redefine ready-channel semantics, or change live mapping
replacement. Those boundaries must be examined in the channel-state audit.
No persistent identity, permission policy, radio or preview behavior changes.

Validation: native case 1031 passes 104 assertions, including loss of the previous
key, fresh capability negotiation, repeated resets, retained privilege/disabled
policy and no reset-time output/storage side effects. Case 1032 checks placement
in the shared builder; it is a source-wiring check, not a real network reconnect.
Eight targeted cases 1031/1032/1033/1051/1052/1304/1428/608 pass 521 assertions.
The baseline fails the new reset cases. Native full-main compilation needs the
installed host dependencies (local Config::Simple is absent); host compilation
and one full suite remain mandatory before commit. No live service was restarted.

Next bounded audit: trace external NAMES accumulation/publication and Fullop
readiness across reconnect and interrupted synchronization, then record the
remaining identity consumers without changing their durable keys by default.
