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
| 1 | Connection-specific IRC identity | ASCII/RFC1459/strict mappings; capability replacement/removal; reconnect; bot exclusions and authorization consumers; durable-key compatibility | Partly covered. MB1256 fixes conversational exclusions; MB1257 fixes Fullop capability withdrawal. MB1258 resets Fullop at transport construction; MB1261 rejects obsolete 005/324 observations. Remaining identity consumers stay open. |
| 2 | Trustworthy channel state | JOIN followed by partial NAMES/WHO/MODE; concurrent NICK/PART/KICK; end-of-list; disconnect/rejoin; decisions before synchronization | Partly covered. MB1259 retires inherited member snapshots; MB1260 rejects obsolete NAMES callbacks. MB1262 also rejects obsolete membership/MODE events. MB1263 guards login/disconnect ingress; MB1264 binds deferred startup to its transport. MB1265 preserves JOIN/NICK changes in buffered NAMES. Synchronized-decision boundaries remain open. |
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


## MB1259 — Retire member snapshots with their transport

Base `bd7695c4fae1a5ffcac5283c5047ef94a17e025a` is committed MB1258 and matches
all tracked files of the 2026-11-12 19:25:53 snapshot. Commit presence does not
establish a numerical host acceptance result or running-version activation.

Reproduced gap: [NAMES handlers](../mediabot.pl) accumulate chunks in
hChannelsNicksTmp, publish membership in hChannelsNicks and record completion in
hChannelsNicksEnd. These three maps survived transport replacement. Appending a
fresh chunk after an interrupted old snapshot therefore retained old members.
The old complete snapshot and its completion flags were also still available.

[setIrc](../Mediabot/Mediabot.pm) now deletes these observations on an actual
transport identity change, including detachment. Retirement precedes output
cleanup callbacks, so a reentrant replacement can publish its own new observations
without the outer call erasing them. Reassigning the same object preserves all
three maps. Configured channels and durable user/permission state are unchanged.

Validation: 16 new checks extend existing native lifecycle case 1311. A local
probe loads the real Mediabot module with unrelated import dependencies stubbed;
the baseline fails 9 checks, while the corrected module passes all 16. This is
not a live IRC replay. Nine neighboring cases 1031/1032/1033/1051/1052/1304/1428/
1520/608 pass 655 assertions. Native unmodified module loading and full case 1311
need installed dependencies (local Config::Simple is missing). Cases 388 and 744
pass another 75 assertions; case 1392 is blocked by the same missing dependency. Host syntax,
expanded targeted validation and one complete suite precede commit.

Row 2 remains partial: this removes inherited observations, but does not reject
late events from old IRC objects, gate every moderation action until channel
synchronization, or handle every same-connection PART/KICK/rejoin boundary.
Next: audit callback authority and synchronization readiness on the real event
path before adding further state machinery. Rows 3–5 remain to be assessed;
this bounded correction does not reopen the completed architecture extraction.


## MB1260 — NAMES callbacks must belong to the installed transport

Base `0cce27e8c7a6325c1a0228fdb3bf2a475d72067e` is committed MB1259 and matches
all tracked files of the 2026-11-12 19:40:58 snapshot. Commit presence alone is
not a numerical host acceptance result or a live activation claim.

Reproduced in an isolated handler replay: after transport replacement, an old
353 can append to the successor's NAMES buffer and an old 366 can consume that
buffer, mark it complete, publish counts and call Fullop's sweep. Clearing maps
at replacement (MB1259) does not itself prevent later callbacks rebuilding them.
This replay establishes the handler gap, not the frequency of live late events.

Both [NAMES handlers](../mediabot.pl) now compare the callback source object's
reference identity with the installed IRC transport, before logging or parsing.
Missing or replaced transports are ignored. Current-transport normalization,
accumulation, ordering, deduplication, completion metrics and sweep are preserved.
The [Net::Async::IRC::Protocol callback contract](https://metacpan.org/pod/Net::Async::IRC::Protocol)
passes the IRC object as the first argument; no nickname/network-text comparison
is used to infer transport identity.

Validation: case 1032 adds 14 checks replaying the actual two handler bodies with
bounded collaborators; baseline fails 9, corrected case passes all 47 assertions.
This source-body harness is explicitly not native full-main integration. Eleven
targeted cases pass 744 assertions. Native main compilation and full integration
remain target-host gates because local Config::Simple/Net::Async::IRC dependencies
are absent. Host syntax, expanded targeted lane and one full suite precede commit.

Scope remains bounded: old events of other types, the interval before replacement,
reentrant changes during a current handler, and synchronization readiness on the
same connection are not solved by this guard. Next: audit shared callback authority
and channel readiness, then give remaining roadmap rows explicit verdicts rather
than treating handler presence as proof. No schema, configuration or service action.


## MB1261 — Server observations require the current transport

Base `7766960240c0c27a941e6ca8299d0f8f12511848` is committed MB1260 and matches
every tracked file of the 2026-11-12 19:57:47 snapshot. Commit presence does not
establish a numerical host acceptance result or activation on a live bot.

Reproduced by replaying the actual numeric handler bodies with native Fullop and
ConversationRuntimeState objects: an old 005 overwrites current network, mapping
and batching rules and invalidates conversation generations. An old 324 replaces
the current channel key with an obsolete value. This demonstrates the handler
authority gap, not an observed live incident or a claim about event frequency.

The [005 and 324 handlers](../mediabot.pl) now require callback-source reference
identity with the installed transport before parsing/logging. This extends the
existing NAMES entry guard without changing policy defaults. Current 005 still
reaches both policy owners, including conversation updates when Fullop throws;
current 324 still records parameter-bearing modes. Absent/detached sources have
no effect. No persisted identities, permissions or configuration are changed.

Validation: 11 new isolated replay checks in case 1032; baseline fails 8, corrected
case passes all 58 assertions. Case 1236 now supplies its installed transport,
retaining its parser-failure and generation tests. Twelve targeted cases pass
816 assertions. Handler extraction is explicitly not native full-main integration.
Local missing Config::Simple/Net::Async::IRC dependencies leave native main syntax
and complete installed-host validation mandatory before commit.

Next bounded audit: membership events JOIN/PART/KICK/NICK/QUIT and MODE still need
source authority review. Login/disconnect events and readiness before synchronization
also remain open. Consolidate these findings into row-2 acceptance; do not call
all IRC callbacks protected. Rows 3–5 retain the same finite audit scope.


## MB1262 — Membership and moderation events require their transport

Base `46b89d408fc0db4ce031f2945a36b97cf5fbee04` is committed MB1261 and matches
all tracked files of the 2026-11-12 20:11:00 snapshot. No numerical target-host
acceptance or running-version activation is inferred from commit presence.

The [JOIN/PART/KICK/NICK/QUIT/MODE handlers](../mediabot.pl) previously accepted
obsolete callback sources. An isolated replay demonstrates member additions,
removals/renames, authentication logout/rename, observer/audit activity and Fullop
calls after the source transport has been replaced. This is a reproduced handler
gap, not evidence of a live server incident or an estimate of its frequency.

All six handlers now check reference identity against the installed IRC object
before logging, parsing or side effects, matching the existing 353/366/005/324
contract. Current events retain the existing behavior. No authorization rule,
network mapping, persisted identity, database schema or configuration is changed.

Validation: 60 checks extend existing case 1032 with the six actual extracted
handler bodies and recording collaborators. Baseline fails 22; corrected case
passes 118 assertions. The accepted path checks existing member updates and
policy/auth calls, while old/absent/detached sources leave state and collaborators
untouched. This remains an isolated replay, not full native IRC integration.
The karma ingress fixture in case 1358 now explicitly installs its replay source;
local execution is blocked by missing Config::Simple, so it remains a mandatory
host gate. Nineteen available targeted cases pass 1,040 assertions. Host native
syntax, expanded targeted lane and one full suite run before commit.

Checkpoint: transport replacement now retires member snapshots and guards NAMES,
capabilities/mode snapshots and the six membership/MODE ingress paths. This does
not establish authority for every callback. Next examine login/disconnect/error
entry points, then same-connection synchronization readiness and record row-2's
remaining limits. Reentrant replacement midway through a handler and the period
before transport replacement remain outside these entry guards. Rows 3–5 retain
their finite audit scope; no new structural extraction is being opened.


## MB1263 — Login and disconnect ingress ownership

Base `5a14e4b87d75c94b7e48b73aad0053ccfd8b470c` is committed MB1262 and matches
all tracked files of the 2026-11-12 20:36:02 snapshot. Commit presence alone does
not establish target-host test totals or live activation.

Replaying the actual [on_login, ERROR and KILL bodies](../mediabot.pl) shows that
an obsolete transport can reset authentication, change connectivity and server
selection, rerun login initialization, or complete a requested process shutdown.
The callbacks now require source reference identity with the installed transport
before the first effect, including the login exporter reset. Accepted current
login and disconnect/quit branches retain their previous behavior. No new retry
policy, configuration, permission, schema or service action is introduced.

36 new checks extend existing case 1032. The unchanged runtime fails 11; the
corrected case passes all 154 assertions. The local targeted run passes 1,107
assertions across 21 available cases, with case 858 unable to load because
Net::Async::IRC is absent. A separate attempt at native XAuth protocol case 1223
has the same missing dependency. These are blocked validations, not passes;
the package requires both cases, native main syntax and the complete suite on
the installed host before commit. Extracted callback replay is not full native
protocol integration.

Next bounded review: timers created by an accepted login can outlive that login;
the entry guard does not cancel those closures. Examine their connection ownership,
then synchronization readiness within one connection and consolidate row-2's
acceptance/residual limits. Other unreviewed callbacks, replacement midway through
a handler and the interval before transport replacement remain outside this
increment. Rows 3–5 retain their existing finite audit scope.


## MB1264 — Deferred login work retains transport authority

Base `dd9459b45ed1c7126ca3df61ab97545e44bc9c2d` is committed MB1263 and matches
all tracked files of the 2026-11-12 20:49:08 snapshot. No host test totals or live
activation are inferred from that commit.

The actual [login handler](../mediabot.pl) schedules sorted channel JOINs and
later WHO queries. Replaying its stored closures after transport replacement
reproduces JOIN and WHO work against the new connection. An entry guard on the
original login cannot protect these later callbacks.

The closures now share a weak reference to their originating transport and
check it against the installed transport before effects. JOIN checks again after
logging and after joinChannel returns, so replacement during that call cannot
schedule a follow-up WHO. An expired weak reference or detached bot is inert.
Current work retains channel keys, sort order, 1.5-second staggered JOIN spacing,
the three-second WHO delay and the existing WHO connected-state check.
No configuration, schema, retry policy or service operation is changed.

Validation: 34 deterministic checks extend case 1032 using its actual extracted
login body and recording timers/collaborators. Baseline fails 16; corrected case
passes 188 assertions. Twenty-one available targeted cases pass 1,141 assertions.
This is isolated replay, not native Net::Async::IRC integration. Local native
main and protocol integration dependencies remain unavailable; the host package
requires native syntax, the expanded targeted lane including cases 858/1223,
and a complete suite before commit.

Limit: this retires callback authority, not the pending timer objects themselves;
they follow their existing expiry lifecycle. It does not create a new login
session epoch for reuse of the very same IRC object, or change other startup,
service authentication and channel-join paths. No network incident is asserted.
Next: review same-connection NAMES/WHO/MODE synchronization and decisions made
before completion, then consolidate row-2 evidence and residual limits. Rows
3–5 retain their finite scope; the architecture extraction chapter stays closed.


## MB1265 — Interleaved arrivals and renames survive NAMES publication

Base `554ceb25df68df661787e188d85502e77720f6ec` is committed MB1264 and matches
all tracked files of the 2026-11-12 21:03:09 snapshot. Commit presence is not a
numerical host acceptance result or confirmation of runtime activation.

The [membership and NAMES handlers](../mediabot.pl) update published lists on
JOIN/NICK, while 366 replaces that list with buffered 353 chunks. In a replay
of the actual handlers, an interleaved newcomer disappears at 366 and an old
nickname is republished, including in the list sent to Fullop. PART/KICK/QUIT
already use [channelNicksRemove](../Mediabot/Helpers.pm) to update pending data.

JOIN now also appends to an existing pending buffer on the matching channel,
using the same lowercased channel comparison as removal. NICK updates every
exact old-nickname occurrence across pending lists, including duplicates and
channels without published membership. Final deduplication and Fullop sweep
remain at 366. No new pending transaction is created by an ordinary JOIN/NICK.
The existing nickname comparison policy, auth/session behavior, live membership
handling, database schema and configuration remain unchanged.

13 new checks in case 1032 replay interleaved 353/JOIN/NICK/353/366 and verify
both publication and Fullop's input. The baseline fails 6; the corrected case
passes 201 assertions. Twenty-one available targeted cases pass 1,154 assertions.
This is extracted-handler replay, not native full-main integration. Local missing
Net::Async::IRC/Config::Simple dependencies leave native syntax and installed
integration gates to the host package, followed by one complete suite before commit.

Limits: this reconciles already buffered chunks with subsequently observed events;
it does not invent transaction identifiers or reject a later stale fragment from
the same transport. Exact nickname matching and existing channel case comparison
are retained rather than expanding identity policy in this patch. It does not
establish a complete NAMES/WHO/MODE readiness barrier. Next audit the consumers'
decisions before synchronization completes, then consolidate row-2 evidence and
residual limits. Rows 3–5 retain the accepted finite scope.
