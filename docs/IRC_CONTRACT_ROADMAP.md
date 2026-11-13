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
| 2 | Trustworthy channel state | JOIN followed by partial NAMES/WHO/MODE; concurrent NICK/PART/KICK; end-of-list; disconnect/rejoin; decisions before synchronization | Partly covered. MB1259 retires inherited member snapshots; MB1260 rejects obsolete NAMES callbacks. MB1262 also rejects obsolete membership/MODE events. MB1263 guards login/disconnect ingress; MB1264 binds deferred startup to its transport. MB1265 preserves JOIN/NICK changes in buffered NAMES. MB1266 keeps independent lists/statuses across 324 refresh. MB1267 retires Fullop observations on own departure/rejoin. Bounded review checkpoint below: partly covered, residual readiness limits explicit. |
| 3 | Control traffic under pressure | Actual transport queue ownership, caps, priorities and penalties; saturated previews alongside control commands; stale output after reconnect | Partly covered, bounded checkpoint MB1270: MB1269 PONG priority is committed; receipt/recovery probes document the remaining queue-cap, penalty and keepalive limits. No global backpressure guarantee. Next assess row 4; carry keepalive recovery into row 5. |
| 4 | Correct authority over time | Identity changes, host/account changes, explicit revocation, channel/global scopes and queued privileged work | Partly covered, bounded checkpoint MB1276: MB1271–MB1275 correct selected cache/session revocation paths. Account-wide auth, Auth nick folding and unsupported IRCv3 notification semantics remain explicit limits. Proceed to row 5. |
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


## MB1266 — Channel MODE refresh preserves independent observations

Base `e395a62aaf05c24b06c443ff592d1ada41361aea` is committed MB1265 and matches
all tracked files of the 2026-11-12 21:22:00 snapshot. No target-host test total
or runtime activation is inferred from commit presence.

[Fullop::remember_channel_modes](../Mediabot/Fullop.pm), called by the 324 handler,
previously replaced simple, scalar, list and status observations together.
[IRC client protocol section 5.2](https://www.rfc-editor.org/rfc/rfc2812#section-5.2)
describes channel-mode and ban-list replies separately. A channel-mode refresh
must not infer removal of independent observed bans or member statuses.

Native component reproduction: accept a privileged +b/+o, receive +mkl then +nt
snapshots, and receive the same +b again. Previously the snapshot erased the
known ban, so the duplicate was reversed with -b. Now the snapshot replaces only
simple/scalar maps. Known list/status entries survive; explicit -b/-o still remove
them. Another channel is untouched and reset_connection still clears everything.
No new sanction policy or authorization exemption is introduced; the existing
handling of the actor remains unchanged even when no correction is required.

Twelve native Fullop checks extend case 1031: baseline fails 4; corrected case
passes 116 assertions. Twenty-one available targeted cases pass 1,166 assertions.
The package also verifies the extracted main-handler case; native full-main and
protocol integration still require the installed host dependencies, followed by
one full suite before commit. No schema/configuration/service action is performed.

Readiness checkpoint: Fullop intentionally oppes individual JOINs immediately
and sweeps NAMES at 366. Its protected-mode corrections use event arguments and
known state; this patch prevents losing known information during refresh. It does
not establish that every correction is safe with unknown prior scalar state,
nor add a WHO/MODE/NAMES completion barrier. Next consolidate those unknown-state
and departure/rejoin cases into a bounded row-2 verdict before moving to control
traffic (row 3); retain residual risks rather than claiming full synchronization.


## MB1267 — Channel departure/rejoin and row-2 checkpoint

Base `50b110fa16fb1b8ad26c167a4810872d286b5ae9` is committed MB1266 and matches
all tracked files of the 2026-11-12 22:01:49 snapshot. No numerical target-host
acceptance or activation is inferred from commit presence.

Replaying actual self PART/KICK handlers with native Fullop reproduces retained
channel modes and delegated-ban correlations after departure. The new
[reset_channel](../Mediabot/Fullop.pm) removes both for the folded channel only.
[Ingress](../mediabot.pl) calls it on self PART/KICK, before KICK's rejoin request,
and on self JOIN before activation. Other-user departures and obsolete transports
do not retire this state. Network capabilities, other channels, policy callbacks
and persistent ChannelBan storage are untouched. Repeated/invalid resets are safe.

23 checks extend case 1032: baseline fails 8; corrected case passes 224 assertions.
The departure replay uses native Fullop but extracted executable callbacks;
self-JOIN placement additionally has a source wiring check, not native startup
integration. Twenty-one available targeted cases pass 1,189 assertions. Native
main/protocol integration still requires installed host dependencies; the package
runs those gates and one full suite before commit. No restart/config/schema change.

### Bounded channel-state verdict: partly covered

| Expected guarantee | Evidence / owner | Verdict and limit |
| --- | --- | --- |
| New transport cannot inherit old observations | setIrc, Fullop reset_connection; MB1258–1264 | Covered for selected snapshots/ingress/startup closures; not every callback. |
| Buffered NAMES preserves subsequent membership events | channelNicksRemove, JOIN/NICK and 366; MB1265 | Covered for already received chunks; no transaction ID for delayed same-connection fragments. |
| MODE refresh does not erase independent lists/status | Fullop remember_channel_modes; native case 1031, MB1266 | Covered for known observations; not proof of a complete initial list. |
| Leaving a channel cannot preserve Fullop authority from that membership | reset_channel plus own PART/KICK/JOIN; MB1267 | Implemented/tested locally; installed-host acceptance remains required. |
| Decisions wait for complete NAMES/WHO/MODE | Fullop handle_join/sweep_channel/handle_mode | Not guaranteed: immediate op-on-JOIN is existing policy; there is no combined readiness barrier. |

Unknown-state limit: scalar restoration uses an observed previous value (or the
argument of a removed category-B mode); an unknown removed category-C value is
not reconstructed. Existing sanctions can still occur without a reconstructable
correction. This checkpoint does not certify such behavior as fully synchronized
or change the established +Fullop policy. Likewise same-transport delayed replies,
reentrant replacement outside the checked paths, exact nickname matching and
per-user status refresh across NICK/PART remain residual audit items, not hidden
parity claims. A full synchronization state machine is not added in this patch.

The selected bounded row-2 defects are delivered through MB1267, pending its host
acceptance. Keep the verdict partly covered and retain these limits. Next work
moves to row 3: trace the actual Net::Async::IRC output queue and Mediabot control
traffic under load. Rows 4–5 still require explicit verdicts. The roadmap is not
declared complete and the architecture extraction chapter remains closed.


## MB1268 — Characterize control traffic at the real transport boundary

Base `79fcb05ddb8afe16635cb9b19c30293599c350d0` (MB1267) matches every tracked
file in the supplied 2026-11-13 04:38:50 snapshot. Commit presence is not a
numerical host-suite result or a claim about the running service.

Expected contract: pending previews must not indefinitely postpone automatic
PONG or urgent control traffic. Complete reply frames retain their order;
write-completion Futures must retain their meaning. Already-written TCP bytes
cannot be overtaken. Control priorities cannot compensate for a blocked event
loop or a genuinely unwritable socket.

### Owners and observed boundaries

| Owner | Existing behavior | Limit of the guarantee |
| --- | --- | --- |
| `IRC::Sender` | Sanitizes/splits output and calls `do_PRIVMSG` / `do_NOTICE`; opt-in callers retain write Futures | AntiFlood admission applies to enabled channels, not every transport write |
| `IRC::DeferredOutput` | At most 30 physical lines per target, shared response expiry after 120 seconds | This is an application queue, not the socket write queue or a connection-wide cap |
| `IRC::PacedOutput` | Explicit paced PRIVMSG batches; NOTICE calls truncate to 16 lines; transport retirement revokes pending work | No aggregate batch cap was found in `_queue_irc_chunks`; 16 NOTICE lines is per call |
| `Protocol::IRC` 0.13 | Automatic PING handler sends PONG through `send_message`, which calls `write` | No separate control priority in this path |
| `IO::Async::Stream` 0.805 | `write` appends a Writer; flushing consumes queue heads; scalar calls return flush Futures | A write chunk size is not an IRC flood penalty or an aggregate queue cap |

Main `_build_irc` constructs `Net::Async::IRC` without a custom output scheduler.
Native dependency sources examined: [Net-Async-IRC 0.12](https://metacpan.org/release/PEVANS/Net-Async-IRC-0.12),
[Protocol-IRC 0.13](https://metacpan.org/release/PEVANS/Protocol-IRC-0.13), and
[IO-Async 0.805](https://metacpan.org/release/PEVANS/IO-Async-0.805).
The cpanfile does not pin these versions; run the probe on the installed host
before treating this dependency combination as its actual behavior.
The previously inspected pinned Eggdrop server queues explicitly distinguish
mode/normal/help work and calculate penalties. This comparison does not establish
that Eggdrop can overtake bytes already written to TCP either.

### Reproduction and evidence

Run `perl tools/dev/irc-control-probe.pl`. It uses a local AF_UNIX socket pair,
real Net::Async::IRC and its inherited parser/automatic PONG handler. It does not
connect, resolve DNS, log in, load bot configuration or send anything to IRC.
It queues 256 synthetic preview-sized PRIVMSG frames before running the loop,
checks the final payload's flush Future is still pending, feeds PING through
`on_read`, and queues MODE plus a terminating NOTICE. It then drains the peer.
This deliberately models a burst accepted before the next loop turn, not a
measured live server flood or a benchmark of network latency.

Local result: Net::Async::IRC 0.12 / Protocol::IRC 0.13 / IO::Async::Stream 0.805:
256 preview frames precede PONG, and 256 precede MODE. All payloads are intact
and ordered, exactly one automatic PONG and MODE arrive, and write Futures
complete after draining. The probe has a ten-second fail-fast deadline and
fails on malformed/lost output. Its JSON reports observed positions rather than
asserting that FIFO is desirable; a future correct priority implementation
should not be rejected merely because the positions improve.

Verdict: partly covered, with a reproduced absence of control priority at this
boundary. No live timeout, lost moderation action, or memory incident is claimed.
This diagnostic/documentation delivery changes no runtime policy. Its native
probe and patch-tool tests passed locally; host characterization is still pending.
Earlier paced/deferred retirement coverage is relevant but does not prove every
raw transport writer has a safe reconnect policy.

### Next bounded implementation and exit gate

Design a connection-owned admission/scheduling boundary before Stream::write.
Start with preserving automatic PONG progress through a sustained ordinary-output
backlog. Explicitly cover write Futures, whole-frame order, bounded ordinary
queues, failure/cancellation and retirement on transport replacement. Do not
manipulate IO::Async's private Writer queue, silently drop accepted durable work,
or classify every command as urgent. Preserve login/service and MODE/KICK order.
Inventory raw `write` callers as well as `send_message` callers before wiring it.
Keep broader rate/penalty tuning separate from the first priority correction.
Then give row 3 its final bounded verdict and proceed to rows 4 and 5; this audit
does not reopen the earlier architecture chapter or expand the five-row exit gate.


## MB1269 — Automatic PONG bypasses pending ordinary output

Base `887fcd563f6e5dd66b6f2b0cc3895e32eb1e01f3` is committed MB1268 and matches every tracked file of the supplied
2026-11-13 04:57:52 snapshot. This is not evidence of activation or a numerical
host acceptance result.

[Transport](../Mediabot/IRC/Transport.pm) subclasses the actual Net::Async::IRC
client with C3 method resolution, preserving inherited protocol serialization,
login and automatic PING handling. It admits one write at a time to the native
Stream and chooses complete PONG frames ahead of not-yet-admitted ordinary work.
It never inspects or edits IO::Async's private Writer queue. All ordinary frames
retain FIFO ordering: MODE, KICK, service login, PRIVMSG and NOTICE are deliberately
not promoted. Already-written bytes and the active write cannot be overtaken.

Raw writes used by DBCommands timers and Partyline .raw go through the same
boundary. An opaque producer, partial line or multi-line write disables overtaking
for that transport; it remains FIFO rather than inserting a PONG into an unknown
frame boundary. Calls before loop attachment retain native behavior and are not
covered by the priority guarantee. Main constructs and attaches the transport
before login. Inherited automatic keepalive PING timing is not changed here.

Each returned Future resolves only after its own native write finishes; failed
or retired work is failed, never marked delivered. Cancelling a caller's Future
continues to cancel observation rather than retract already-accepted bytes.
Native on_write/on_flush callbacks remain in use. Pumping happens on a later
loop turn, outside native flush callbacks; recursive sends cannot corrupt the
native writer or overtake earlier ordinary output. Graceful close drains the
application queue before closing; immediate close revokes it. Throwing close-time
consumer callbacks are reported after cleanup rather than stranding later work.

The shared [builder](../mediabot.pl) now creates this transport.
[setIrc](../Mediabot/Mediabot.pm) publishes the successor before retiring the old
transport; its active and pending writes cannot resume on the new connection.
Legacy/custom transports without retire_output retain the existing path. This
is connection-output retirement, not a new whole-bot shutdown coordinator.

Reproduction: `perl -I. tools/dev/irc-control-probe.pl` retains the MB1268 native
baseline. Add `--mediabot` for the production adapter. With Net::Async::IRC 0.12,
Protocol::IRC 0.13 and IO::Async::Stream 0.805, the same 256-frame test changes
from 256 earlier PRIVMSG frames to one before PONG. MODE still follows all 256;
payloads and write acknowledgements remain intact. This proves an offline burst
boundary, not a wall-clock latency guarantee, a server penalty model or a live
incident repair. A blocked event loop/unwritable socket still delays control.

The existing native pacing case 1313 now includes the socket-pair regressions
in [MB1269TransportProbe](../t/lib/MB1269TransportProbe.pl): priority with/without
autoflush, FIFO, per-write Futures, cancellation, callbacks, graceful/immediate
closure, native write failure, recursive completion, raw barriers and setIrc.
Cases 858 and 1223 now use the production adapter for update write receipts and
authentication protocol dispatch respectively. Standalone checks exercise 38
assertions; the native case also executes three actual Mediabot integration
checks. After installing missing local dependencies, all 18 targeted cases pass
1,779 assertions, including those integration checks. Native mediabot.pl and
Mediabot.pm syntax checks also pass. Earlier dependency-blocked attempts are not
counted as passes. Host syntax, the same targeted lane and one complete suite
remain mandatory before commit. No full local suite or restart is claimed.

Remaining row-3 scope: this preserves the existing absence of an aggregate
transport byte/count cap; it does not claim bounded memory under indefinite
producers. Select overflow semantics with durable-write callers before adding
such a cap. Also evaluate keepalive PING timeout start versus actual write and
network penalty/rate control. These are explicit residuals, not silently solved
by PONG priority. Continue within row 3, then assess authority and recovery rows
4–5; the finite roadmap exit gate is unchanged.


### MB1269 R2 — Restore native timers between test fixtures

Host validation stopped before commit: case 1313 failed its MODE/NOTICE tail
checks. Reproduced with IO::Async 0.804: the unexpected final frame was a PING,
not an inversion of the two commands. The preceding pacing fixture had localized
Countdown::new to force delay=0 for the entire test file; the newly appended
transport probe inherited that override and immediately fired its keepalive.

R2 scopes that override to the original pacing checks and asserts that the native
constructor is restored before the transport probe. It preserves all wire-order
assertions and runtime files. The corrected native case passes on both 0.804 and
0.805; expanded 18-case validation and one full host suite remain commit gates.
The repair package accepts only the exact uncommitted R1 state on the same base;
it does not reapply the original patch or overwrite unrelated edits.


## MB1270 — Keepalive receipts and bounded traffic-pressure checkpoint

Base `f55329861736405da97a49eb219316712439eac7` is committed MB1269 R2 and
matches every tracked file of the supplied 2026-11-13 05:35:24 snapshot. The
maintainer accepted continuation after that delivery; commit presence does not
supply an exact host test total or establish that the service loaded this code.
The earlier architecture chapter remains closed.

### What the native timer actually measures

[irc-keepalive-probe.pl](../tools/dev/irc-keepalive-probe.pl) uses two local AF_UNIX
socket pairs, native IO::Async timers, the real parser and public write Futures.
It neither logs in nor reads configuration nor contacts a server. Its observer
subclass records PING receipts and forwards every write unchanged. The stalled
peer initially does not read: 256 ordinary frames exceed a 4096-byte requested
send buffer. At the native timeout callback, the last payload and PING receipts
are pending and the bytes already available to the peer contain no PING. Reading
then resumes: all 256 frames and the single PING survive, in ordinary FIFO order,
and their receipts complete. A separate responsive peer answers the actual PING
through the socket and produces one on_pong_reply without a timeout.

Commands (run from the repository root):

```bash
perl -I. tools/dev/irc-keepalive-probe.pl
perl -I. tools/dev/irc-keepalive-probe.pl --mediabot
python3 tools/dev/test_irc_keepalive_probe.py
```

The probe configures a 0.01-second idle delay, 0.03-second stalled-peer response
deadline and a two-second responsive-peer deadline, with a ten-second process
ceiling. It asserts event/receipt ordering, not elapsed performance. Those values
are probe-only; production defaults are unchanged. Tests characterize the current
behavior explicitly and must be revisited if that dependency contract changes.
Local tests pass with Net::Async::IRC 0.12, Protocol::IRC 0.13 and IO::Async 0.804
and 0.805. The existing PONG priority probe remains a separate regression gate.

In Net::Async::IRC::Protocol 0.12, the idle timer calls send_message(PING), records
ping_send_time and immediately starts pongtimer. It does not wait for the returned
flush Future. on_message_PONG calculates lag from that timestamp. Thus the budget
and reported lag can include local output waiting; the timeout is not proof that
a flushed PING went unanswered. The timeout callback itself does not close the
stream. Source review of the native builder and Mediabot modules found no configured
on_ping_timeout callback. This probe intentionally installs one to observe the
event; it does not demonstrate production reconnection or a real incident.

### Row-3 verdict: partly covered, with explicit limits

| Guarantee | Evidence | Disposition |
| --- | --- | --- |
| Automatic PONG passes pending ordinary whole frames | MB1269 native socket-pair tests; installed dependency probe | Implemented; active/native bytes and raw-write barriers remain limits. |
| Ordinary ordering, flush receipts and old-transport retirement | MB1269 cases 1313/858/1223 and native probe | Covered for the tested paths; not server processing acknowledgements. |
| Whole-connection bounded memory | DeferredOutput has a per-target cap; Transport/PacedOutput have no aggregate cap | Not guaranteed. Explicit residual, no silent-drop cap added. |
| Keepalive timeout means the peer ignored a sent PING | MB1270 stalled socket and receipt probe | Not guaranteed: local waiting counts. Recovery policy remains for row 5. |
| Network-specific flood penalties | Native FIFO/admission plus opt-in channel AntiFlood | No equivalent global penalty scheduler; explicitly outside this bounded correction. |

Overflow decision: preserve current admission semantics in this delivery. Ordinary
Sender calls use void context unless write_futures is requested; Update's final
notification does request receipts. Fullop::_send, raw DB timer commands and
Partyline .raw also reach the same transport. A new failed Future alone would not
notify every void-context caller. Silent dropping, arbitrary disconnect-on-full
and prioritizing all MODE/KICK writes are therefore not introduced as incidental
fixes. Bounded global admission needs its own caller-visible rejection policy;
its absence remains a reliability limitation, not a claim of Eggdrop parity.
No live traffic measurement or server penalty calibration was performed.

This is a tooling/documentation checkpoint, not another runtime refactor. Verify
the two probe transports and their tests on the host, then use the existing
commit.sh. No full bot suite is required for these non-runtime files. The fixed
five-row scope is unchanged: proceed to row 4's authority/revocation audit, then
row 5's reload/recovery verdict. Row 5 must explicitly decide how to detect a
stalled/silent connection without mistaking an unflushed PING for a peer failure;
do not infer recovery merely from the dependency's callback name. The overall
roadmap is not complete, and global backpressure remains explicitly unimplemented.


## MB1271 — Successful modinfo retires its cached channel grant

Base `448485e1802a025226f205e9cc54723a883eb9c0` is committed MB1270,
retrieved from the development branch. No newer local snapshot was supplied.
The architecture chapter remains closed; this is the first bounded row-4 fix.

Expected contract: after a successful channel-level change, the next authorization
must use the new level, including before success callbacks run. Reproduction uses
native UserCommands::userModinfo_ctx and Helpers::checkUserChannelLevel with an
in-memory SQL fixture, without a database connection or source-body extraction.
Prime a level-450 grant through the real helper, issue an authorized modinfo level
0, then ask the real helper for level 400. Baseline still admits it because its
60-second cache was not invalidated. The inverse promotion also remains denied.
Six assertions fail on baseline; this is an offline demonstrated stale decision,
not evidence that an operator abused it on a live channel.

The command now deletes only the confirmed target user/channel cache key after
its update helper succeeds and before botNotice/logBot. It uses the existing
lowercase channel key shared with checkUserChannelLevel and channel add/delete.
It does not change IRC casemapping rules, permission hierarchy, SQL/schema,
authentication or the cache TTL. Other channels/users retain their cache objects.

Case 72 now runs [MB1271ModinfoCache](../t/lib/MB1271ModinfoCache.pl), covering
promotion/demotion, differently cased channel spellings, reentrant authorization
from the success notice, failed prepare/execute, unauthenticated and denied
callers, and unchanged automode/greet behavior. Failed writes do not discard the
previous cache; successful lookup refreshes once and uses the existing cache
again. Existing static DB checks remain present. SQL failures are simulated at
the DBI-shaped boundary; no production database or IRC connection is involved.

Targeted native acceptance and one complete --progress suite are required on the
host before commit. The existing commit.sh owns VERSION and push. No runtime
activation/restart is performed by the delivery.

Row 4 is still in progress: account-wide level/session invalidation, host/account
changes, explicit logout and delayed privileged work need their own verdict.
This patch does not revoke already-emitted wire commands or mutate an existing
Context's memoized user object. Keepalive recovery remains a row-5 item; aggregate
queue caps and global penalty scheduling remain the explicit row-3 limitations.


## MB1272 — Global role updates retire fullmask resolution

Base `c38134fef111eed4f4c99896d12ccc8a86792968` is committed MB1271 and matches all tracked files of the supplied
2026-11-13 06:07:49 snapshot. This does not establish live activation or provide
a numerical host-suite result. Continue the bounded authority-over-time review.

Native Helpers::get_user_from_message caches a Mediabot::User, including its loaded
global role, for five seconds per fullmask. UserCommands::setUserLevel updated SQL
without expiring those objects. An offline replay primes two aliases for the same
account, changes Master to User, and still passes Administrator checks through
both cached aliases. A promotion has the inverse stale-denial behavior. This is
a reproduced stale authorization decision, not a claim of live exploitation.

The setter now calls the existing Helpers::clear_user_cache after execute succeeds
and before finish. It clears all short-lived fullmask objects and timestamps:
SQL nickname collation and live nicknames need not match a simple Perl comparison,
so selecting cache entries by display nickname could miss an alias. The tradeoff
is fresh resolution for other cached users after this infrequent administrative
mutation. Auth sessions, channel-level caches, database roles and TTL policy are
otherwise unchanged. Previously handed-out User/Context objects are not rewritten.

A prepare failure also no longer calls finish on an undefined statement. Failed
prepare/execute retains the previous lookup cache. Cleanup exceptions after a
successful UPDATE remain visible, but cannot leave stale cached roles behind.
No SQL transaction/retry, authentication-policy change or schema change is added.

Case 75 extends its existing checks with [MB1272GlobalGrant](../t/lib/MB1272GlobalGrant.pl).
The real setter, resolver, candidate selection, User construction/load_level and
has_level methods run against a DBI-shaped in-memory fixture; matching/autologin
and bot session hooks are controlled collaborators, not a live login test.
Seventeen assertions fail on baseline, including the missing-statement cleanup;
corrected validation covers aliases, cache ages, promotion/demotion, unchanged
sessions/channel grants, binds and cleanup errors. The full host suite remains
mandatory before commit, with --progress. No service action is performed.

Row 4 remains open for host/account changes, logout and delayed privileged work.
This fix addresses fresh message resolution, not reauthorization of already
queued commands or previously captured Contexts. Row 5 still owns the explicit
keepalive recovery decision. Neither issue is declared solved by cache expiry.


## MB1273 — Last-session retirement expires unregistered cached aliases

Base `b39f665f43a6af20edfccab4c0e0f060c13ad34b` is committed MB1272 and matches every tracked file in the supplied
2026-11-13 06:32:10 snapshot. No numerical host result or live activation is inferred.

Auth::_invalidate_bot_session clears its exact stored fullmask. Helpers caches
resolved User objects for five seconds by the complete prefix string. Variant
spelling or earlier nicknames can therefore retain authenticated objects outside
the Auth session table after the account's last session closes. A numeric logout
with only legacy logged_in state also lacks a session mask to clear.

Auth::_invalidate_bot_uid now invokes the existing optional clear_user_cache hook
without a mask, retiring objects and timestamps before removing mirrored UID
state. All short-lived lookups refresh, including those for other accounts; their
Auth sessions and logged-in flags remain intact. A logout while another session
for that same UID survives retains existing account authentication and does not
invoke account retirement. Account displacement uses the same existing owner.
No SQL, session key normalization, autologin policy or schema changes are made.

The existing native case 591 now uses real Mediabot::User cache values and the
native Helpers::clear_user_cache in its bot fixture. Six new assertions fail on
baseline. The corrected case passes 65 assertions, including last-session,
legacy numeric and skip_db paths, case/old-nick aliases, unrelated account
sessions and surviving same-account sessions. Nine targeted cases pass 317
assertions locally. SQL remains a fixture; this is not a production login test.
The guarded package requires native syntax, these targeted cases and one full
--progress suite on the host before the existing commit.sh owns VERSION/push.

Limits: existing User/Context references already handed out are not rewritten.
The optional hook retains its historical best-effort exception handling; a broken
custom bot hook is not guaranteed to invalidate anything. A failed database auth
reset and automatic reauthentication policy are separate issues: clearing this
cache does not claim to prevent fresh authentication allowed by those paths.
No runtime configuration, service restart or database migration is performed.
Row 4 still needs host/account-change and delayed-privileged-work verdicts;
row 5 still owns the keepalive/reload/recovery decisions.


## MB1274 — Committed account deletion revokes live authorization

Base `3154036bcfc674106ab827f1c1d794209c76253f` is committed MB1273 and matches every tracked file in the supplied
2026-11-13 07:03:58 snapshot. Commit presence does not supply a host-suite count
or prove that the running process loaded these changes.

Row-4 explicit revocation review found that delUser_ctx deletes USER and its
relations transactionally, then reports success without clearing its resolved
User objects, channel-level grants or Auth sessions. Offline reproduction with
native Context/User/Auth and an in-memory SQLite database leaves both live aliases
logged in after successful deletion. Twelve assertions fail on the baseline.

After confirmed commit, the handler now expires fullmask objects/timestamps,
removes channel-grant keys for the exact UID followed by the NUL separator, and
calls Auth::logout(uid, skip_db => 1) when the existing Auth owner supports logout.
No auth UPDATE targets the deleted row. Retirement precedes the success logger,
notice and audit callbacks. Clearing lookup objects for other accounts only forces
fresh resolution; their sessions and channel grants remain. A bot without an Auth
owner still clears the resolution/channel caches. No additional owner is created.

The existing case 163 now runs [MB1274DeletedAccount](../t/lib/MB1274DeletedAccount.pl)
in addition to its established 36 transaction/permission scenarios. The new
fixture exercises successful deletion, absence of Auth, confirmation only, and
a real deferred-foreign-key commit failure/rollback. It verifies both aliases,
multiple channels, UID 7 versus 70, unrelated account authentication, callback
ordering and absence of duplicate auth SQL. The native helper uses no production
configuration or server. Its 43 assertions extend case 163 to 60; eight related
cases pass 543 assertions locally. The host must compile UserCommands, run those
cases and one complete --progress suite before commit.sh owns VERSION and push.

No schema migration, SQL deletion-order change, confirmation-policy change,
service action or new permission rule is introduced. Existing captured Contexts,
previously transmitted commands and custom Auth implementations are not certified
by this fix. It uses the established native Auth retirement behavior, including
its optional cache hooks. Row 4 still requires verdicts for host/account changes
and delayed privileged actions before row 5's recovery/reload assessment.


## MB1275 — Revoke obsolete Partyline authority on account mutation

Base `26c805cdd68d3147708910d21dfb89888f70ffff` (committed MB1274) matches
all tracked files of the supplied 2026-11-13 07:23:29 snapshot.

Reproduced gap: after native setUserLevel downgrades an Owner, the Partyline
session retains its login-time level. Native Privileged::_cmd_eval still arms
its first confirmation, and a retained ShellWatch::_tick publishes a frame.
The local replay used SQLite and seeded successful-login fields; it did not
perform a password handshake, execute eval code, open IRC or demonstrate a live
incident. Auth's IRC sessions and Helpers' caches are separate from this state.

SessionAuth::refresh_account_authority now reads current account/role rows for
active Partyline sessions after successful setUserLevel and committed delUser.
Database collation matches login spellings. New successful logins also record
the UID, preventing a different account with a reused login from inheriting the
session on revalidation. Unchanged privileged accounts keep their sessions;
a changed role (including promotion), missing account, invalid role or failed
read requires a fresh login. SQL-read failure is deliberately fail-closed for
the session whose authority cannot be confirmed.

Logical revocation clears authentication, level and pending eval confirmation
before cleanup callbacks. Native session closure retires watches, console hooks
and runtime state; the captured old stream closes immediately. Cleanup failure
cannot restore authority in retained references. No SQL is added per command or
per watch tick: revalidation occurs only at these explicit mutation boundaries.
No schema, password policy, role hierarchy or service configuration changes.

Existing case 75 adds native SQLite/Partyline regressions for multiple aliases,
SQL case matching, role promotion/demotion, unchanged peers, actual confirmed
account deletion, missing role, read failure, reused UID and cleanup exception.
Retained privileged-action and watch callbacks see revocation. Targeted tests
and one full installed-host suite are required before commit; no live restart or
running-version acceptance is inferred from local checks.

Limits: direct external SQL edits have no notification hook; custom Partyline
implementations without this method are outside the guarantee. Already-started
subprocesses and bytes already delivered are not withdrawn. This is not general
mid-command cancellation. Existing pre-upgrade sessions require the normal code
activation/reconnect; this package does not hot-patch the running process.

Row 4 still needs a bounded host/account-identity verdict, then row 5 must decide
reload/recovery and the documented keepalive gap. Do not enlarge the exit gate
with optional Partyline or Eggdrop features.


## MB1276 — Bound the authority verdict and move to recovery

The [authority checkpoint](IRC_AUTHORITY_CHECKPOINT.md) records source owners,
observable guarantees, the account-wide authentication model and the absence of
an IRCv3 account-notify/chghost authority contract. A new offline developer probe
characterizes prefix cache separation, allowed/unlisted hosts, password-only
logged-out accounts and exact versus RFC-equivalent Auth session keys.

No runtime authentication behavior is changed. Existing committed corrections
MB1271–MB1275 remain the selected fixes; direct SQL changes, captured contexts,
already-started work and protocol extensions are not silently declared covered.
Source and snapshot match at `454bef0573cc9e46790d1e92c2af6299cd6cd8db`.

Row 4 now has a bounded partly-covered verdict. The remaining assessment is row 5:
reuse the lifecycle/reload tests and resolve the keepalive recovery decision from
MB1270. Completion still requires acceptance of selected runtime fixes and a
verdict for row 5; optional feature parity does not extend the exit gate.
