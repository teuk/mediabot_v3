# Mediabot v3 — maintenance review, 17 October 2026

## Scope and evidence

This round reviews the supplied 17 October snapshot with the validated MB828
changes applied. The snapshot starts at `3.6dev-20261016_150730`; a subsequent
commit.sh version bump does not alter the reviewed source contracts.

The review follows configuration/DB persistence, authentication, event dispatch,
worker lifecycles, AI memory, RSS and RandomQuote pacing, URL handling, mbweb
authorization and network-statistics installation. The Mediabot tree contains
165 source files. Reading selected paths and exercising the existing suite is
a cross-cutting maintenance review, not a proof that every project line or
external provider is defect-free.

Five concrete defects are reproduced and corrected in MB829. Existing data,
roles, commands, response pacing and deployment boundaries remain the reference.

## Corrected defects

| Area | Reproduction and effect | Correction | Regression evidence |
| --- | --- | --- | --- |
| AI memory | Rename `Alice` to `ALICE`, or `Te[u]K` to `Te{u}K`. RFC1459 folding produces the same actor hash; deleting the old key also deleted the retained actor and display name. The next request changed `speaker1` to `speaker2`. | Delete the old map entry only when the actor hash actually changes. | Equivalent renames, persisted speaker identity/display, restart, a reply already in flight, distinct participants and erasure. |
| EventBus | A `once` callback emits its own event. It was removed only after dispatch, so it ran twice. A callback consumed by a nested dispatch could also run again when the outer snapshot resumed. | Mark and remove a one-shot before invoking it, with a claim shared by `emit` and `emit_report`. | Self-recursion, nested outer snapshots, newly registered listeners, regular listeners, mixed dispatch and exception isolation. |
| mbweb channel membership | Read the dashboard, remove membership, then read it again within 30 seconds. The process cache returned the former channel rows. A failed fresh membership query could also be hidden by that cache. | Query the current membership for every dashboard response and retain the existing empty-result behavior when the read fails. | The next response removes revoked membership; a failed read never returns previous rows. This concerns channel metadata; it is not evidence that quote/log content bypassed its separate authorization gates. |
| mbweb test stability | The privacy assertion searched the entire JSON for `123` and `456`. Valid timestamps ending in those milliseconds therefore failed. The failure was observed during this review and reproduced with a controlled timestamp. | Assert the actual database/count fields and keep the whole-response check for the private string markers. | Both millisecond values are exercised deterministically for all three non-Owner roles, with the Owner behavior retained. |
| Network-statistics setup | Under `umask 077`, directory creation requested as 0755 still produced 0700. The service account could not traverse the installed app/config directories. Setup also hid which subprocess failed. | Explicit modes/owners for managed directories, without changing the caller umask or private-file modes. Reject symbolic managed paths before installation. Show command basename and exit status, with arguments/output kept private. | Hub and remote-publisher installs/repeats under 077; public traversal, private credentials/outbox, symbolic-path rejection and non-leaking diagnostics. |

The new Perl regression file initially fails 13 of its 47 checks on the original
event/memory code. The membership and timestamp regressions are also exercised
before applying their fixes. The permission issue reproduces the installation
failure already observed on nbot.

## Boundaries checked

- Protected mbweb routes still use the fresh-identity middleware. Owner-only
  database identity/global counts and the repository's quote channel scopes
  retain their existing authorization gates. Removing the dashboard cache adds
  a membership SELECT per dashboard request; this is deliberate freshness,
  rather than an authorization result cached for 30 seconds.
- RSS pacing still commits quota and feed rotation together under its lock.
  RandomQuote keeps revision-gated attempts and does not replay missed intervals.
- HTTP research remains in bounded workers, with verified TLS, bounded source
  data, passage validation and paced short URLs. No AI provider/model/prompt
  change is included in this maintenance round.
- EventBus callback failures still remain isolated and reported. The change
  concerns one-shot lifecycle only; ordinary dispatch keeps snapshot semantics.
- Statistics publishing still uses its separate credentials and durable outbox.
  The maintenance installer is exercised through temporary filesystem fixtures;
  no real Apache/systemd service is deployed by the source package.

## Follow-up work identified

### Configuration-save durability

`Mediabot::Conf::reload` prepares a complete replacement before swapping memory,
but `save` delegates to `Config::Simple::write`, which locks and truncates the
destination before writing it in the dependency used for this qualification.
The wrapper itself provides no atomic-publication contract. A failed
write/process interruption can therefore leave a partial
configuration. This is a source-level durability concern, not a demonstrated
production incident in this review.

A separate change should specify atomic publication, preservation of owner/mode,
the supported policy for symbolic config paths and concurrent runtime/operator
edits. Test failed writes, rename failures and recovery before changing this
shared behavior. The current practice of stopping the instance before operator
configuration edits remains applicable.

### Incremental decomposition

Large modules remain: `UserCommands.pm` has 8,467 lines, `Helpers.pm` 5,440,
`Partyline/Commands.pm` 4,968 and `Mediabot.pm` 4,633 in the reviewed snapshot.
DB connection/session initialization also repeats configuration between startup,
reconnection and isolated workers. These are maintenance costs, not additional
failures established by this review.

Extract one bounded responsibility at a time with its existing behavior tests,
command catalogue and permission/output contracts. A broad rename/reformat pass
would create review noise without demonstrating an improvement.

## Source, deployment and acceptance

The package applies source changes with backups and validation. It does not
commit, push, change private config or operate a running service.

| Component | Required later acceptance |
| --- | --- |
| IRC event/memory code | Restart the development instance after source validation; check a case-only nick change and conversation continuity. Production receives a committed update through the existing updater. |
| mbweb dashboard code | Deploy the canonical dev console source through `install/mbweb_deploy.sh`; check a disposable account's channel removal on its next dashboard request. A bot update does not deploy `/opt/mbweb/app`. |
| Statistics installer | Future canonical setup invocations use the new directory/diagnostic behavior. Existing hub history and tokens need no migration or reset. |

Runtime acceptance is distinct from unit/source validation. In particular, do
not announce this round as deployed on nbot or mbweb until those steps occur.

## Validation

The delivery README records exact local test totals and any sandbox limitations.
Application requires the targeted tests, Node lane, fast lane and full Perl
suite on the development host; any required-check failure restores the payload
source files. The already validated MB828 TLS fixture remains in the base and
is not reverted by this round.
