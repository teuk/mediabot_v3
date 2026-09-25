# API v3 plugin operations

MB750 added a read-only operator view over the API v3 state that already
decides runtime behavior. MB751 added bounded, in-memory failure evidence.
MB752 adds a separate Owner-only action for exact resource/channel containment;
it does not turn evidence into automatic remediation. MB754 adds no Partyline
mutation: its quote-command adoption uses the existing lifecycle, permission
and per-channel policy controls and remains inactive by default. MB757 adds an
explicit, namespace-safe repository cleanup action after the supervised
`short-content-v3` pilot proved that the legacy cleanup verb cannot address
API v3 state. MB758 adds a read-only factoid data capability. MB759 places the
pure `factoid` and `factoids` readers in an inert package behind the existing
lifecycle and per-channel policy controls. MB760 adds an on-only factoid write
facade. MB761 lets the same package request that facade for `learn` and
`forget`, still with no new Partyline mutation, automatic activation or policy
change. `observe` suppresses the shadow write and leaves the historical handler
as the only mutating path. MB762 adds one on-only exact factoid recall increment
to the core facade. MB763 mounts `whatis`; the parser-level `?keyword` shortcut
reaches that same handler and retains its quiet-miss behavior.
MB764 adds one bounded portfolio across installed and loaded v3 packages, then
uses it to supervise the first single-channel development promotion.
MB766 persists reviewed posture, MB767 promotes Quotes on development, and
MB768 proves a persistent production `observe` posture on `#i/o`. MB769 adds
the read-only `data.channel_activity.read` authority. MB770 packages it as
inert `channel-activity-v3`: `compare` and `heatmap` move through the existing
`observe` then `on` gate on development only, with `off`, disable and unload as
exact rollback. No new Partyline mutation or activity write is introduced.
MB771 retains that package only on development `#test`, persists the exact
three grants plus enabled/`on` posture, proves restart restoration and leaves
the existing `quotes-v3` promotion unchanged.
MB772 repairs the IRC updater boundary exposed before the production activity
pilot: an internal `plugins.DATA_DIR`, including the API v3 ledger and plugin
KV documents, is now preserved across release rotation. External absolute
state remains where configured; internal symlinks, traversal and candidate
merges are rejected.

## What is installed and active across API v3?

```text
.plugins overviewv3
```

The first line reports discovered, loaded, enabled, active, ready and limited
package totals plus the number of active channel policies. Each following row
contains only package name/version, installed-or-missing source state,
lifecycle, deterministic readiness/reason and `on`/`observe`/`off` counts.
At most 64 rows are returned. The command is read-only and contains no package
path, channel configuration value, object, service or credential.

## Is the package operationally ready?

```text
.plugins doctor quotes-v3
```

The report includes lifecycle, permission completeness, policy counts,
declared/mounted commands, events and jobs, plus saved migration handlers.
Its status is deterministic:

| Status | Meaning |
| --- | --- |
| `inactive` | package disabled or no channel has `observe`/`on` policy |
| `limited` | package is enabled on a channel but capabilities are missing, or an otherwise-ready resource is quarantined |
| `ready` | package is enabled, has an active channel and every requested capability is effective |

The report is diagnostic, not a health promise about an external endpoint or
database. Previous failures do not change readiness. MB752 adds a quarantine
aggregate; an otherwise-ready package with one or more isolated resources is
`limited (quarantined_resources)`.

## What failed recently?

```text
.plugins failures quotes-v3
```

The view covers API v3 command, event, shared-job and HTTP-callback handlers.
Each record contains only:

- runtime kind and bounded resource name;
- current policy channel, or `-` when none applies;
- integer timestamp and consecutive-failure streak;
- a 16-hex-character, instance-salted SHA-256 fingerprint.

The package ledger retains at most 16 recent records and 128 resource states;
Partyline prints only the newest five. Exception messages are normalized and
hashed inside the core, then discarded from the report. Typed configuration,
paths, service responses, database diagnostics and secrets are not fields.

A successful call resets the matching resource/channel streak without erasing
recent history. Disable/enable preserves evidence for the current loaded
instance. Unload/reload destroys it. This is operational memory, not durable
storage.

## What is quarantined now?

```text
.plugins quarantines quotes-v3
```

This detached view lists at most ten of the 64 exact entries held by the loaded
package instance. An entry is the tuple `kind + declared resource + channel`
with its integer timestamp. RFC1459 channel casemapping applies. Disable/enable
preserves the registry; unload/reload discards it.

The view cannot change state. It contains no exception text, configuration,
service response, plugin object or operator-provided reason.

## Which capabilities are effective?

```text
.plugins permissions quotes-v3
```

The four sets have distinct meanings:

| Set | Meaning |
| --- | --- |
| `requested` | declared by the validated package manifest |
| `granted` | explicitly approved when the instance loaded the package |
| `effective` | requested intersection granted |
| `missing` | requested but not effective |

No grant is added by this command. Reload with an explicit grant list remains
an Owner-controlled operation.

## Why does one channel behave this way?

```text
.plugins why quotes-v3 #test
```

The core resolves the package lifecycle and current RFC1459-folded channel
policy into one decision:

| Decision | Plugin runs | Plugin output | Saved migration fallback |
| --- | ---: | ---: | --- |
| disabled package | no | no | visible when captured |
| `off` | no | no | visible when captured |
| `observe` / `shadow` | yes | no | visible when captured |
| `on` / `active` | yes | yes | suppressed |

The view also distinguishes an explicit `off` policy from an unconfigured
channel, which defaults to `off`. It never prints the channel's typed
configuration values.

## Security and mutation boundary

`doctor`, `failures`, `quarantines`, `permissions` and `why` are available to
authenticated Partyline readers, like `info`. They return only bounded scalar
snapshots and never expose the plugin object, `PluginContext`, service facades,
database handles, paths or secrets. They do not enable, disable, load, unload,
change policy, quarantine, reset history or clear data.

Only an Owner may change one exact quarantine entry:

```text
.plugins quarantine quotes-v3 command quotecount #test
.plugins unquarantine quotes-v3 command quotecount #test
```

Allowed kinds are `command`, `event`, `job` and `http_callback`; the last uses
the declared core resource `callback` and is available only to a package that
requests `http.fetch`. The manager rejects undeclared resources. Both actions
are idempotent and never enable a package or channel.

Quarantine prevents new work and is checked again at deferred dispatch, output
and HTTP completion. It is scoped to the named resource/channel, not the whole
package. Release never clears the separate MB751 failure history. There is no
bulk clear, persistent quarantine, automatic threshold, restart or global
disable in MB752.

## How do I clear API v3 repository state?

First stop visible work through the normal reversible lifecycle, then use the
dedicated Owner command:

```text
.plugins policy short-content-v3 #test off
.plugins disable short-content-v3
.plugins unload short-content-v3
.plugins clearv3data short-content-v3
```

`clearv3data` validates the package slug and asks `PluginManager` to derive the
same private namespace used by `storage.kv`; Partyline never sees a pathname or
internal key. It works for loaded, unloaded and no-longer-installed packages.
Success and already-absent state have distinct bounded messages, and repeating
the command is safe. It removes only the API v3 repository document.

`.plugins cleardata <name>` remains the historical v1/v2 operation. It does
not alias or guess the API v3 namespace, so an identical legacy plugin name
cannot be erased accidentally.

## First controlled development promotion

MB764 promotes only `factoids-v3` on `#test`. Before leaving policy `on`, the
operator collects `.plugins overviewv3`, `doctor`, `permissions`, `why` and
`failures`, proves observe/on parity with one disposable factoid, verifies one
increment per successful explicit/quiet recall, then deletes the evidence.
The exact runbook is [`PLUGIN_V3_PROMOTION.md`](PLUGIN_V3_PROMOTION.md).

MB766 makes the accepted operator posture restart-persistent without enabling
legacy `plugins.AUTOLOAD`. A service restart restores the exact grants,
policies and enabled bit from the validated local ledger. Immediate explicit
rollback remains, and is itself persisted:

```text
.plugins policy factoids-v3 #test off
.plugins disable factoids-v3
.plugins unload factoids-v3
```

The first command returns the channel to the saved historical handler, disable
stops the package while retaining its configuration, and unload removes it
from both the live registry and the next boot.

The second controlled development promotion follows the same boundary:

```text
.plugins policy channel-activity-v3 #test off
.plugins disable channel-activity-v3
.plugins unload channel-activity-v3
```

MB771 accepts `channel-activity-v3` as enabled and `on` only for `#test` after
the MB770 parity proof and a clean restart. No production posture is implied.

MB778 opens the next functional tranche with `playful-v3`. It is enabled and
`on` only for development `#test`, with exact grants and the typed
`ritual_enabled=false` default. Six commands and the dormant job survive a
clean restart; every pre-existing ledger package is fingerprinted before the
change and must remain unchanged. Rollback remains policy `off`, disable, then
unload.

MB781 promotes `short-content-v3` on development `#test` with one explicit
trusted HTTPS endpoint and only the `http.fetch`, `irc.reply` and `storage.kv`
grants. Observe is silent and repository-write-free; on returns one bounded
scalar and advances one namespaced repository revision. A clean restart must
restore the exact policy and zero-failure runtime while every pre-existing
ledger entry remains unchanged. Immediate rollback remains policy `off`,
disable, then unload; production receives no policy.

An IRC `update now` is also a restart boundary. Since MB772, the updater reads
`plugins.DATA_DIR` from the selected private configuration. If that directory
is internal to the release tree, it is copied after shutdown and before the
directory swap, so `.api-v3-runtime-state.json` survives exactly like other
instance state. If it is an absolute external directory, it is not copied and
continues to live outside the rotation. A missing ledger still loads nothing;
the updater never invents or reconstructs operator posture.

## MB784 production portfolio record

MB784 consolidates the accepted production posture without replaying it. Five
packages are persistent enabled/on on nbot `#i/o`: Quotes, Channel Activity,
Factoids, Playful and Short Content. Permissions are complete, failures are
zero after restart, `quiet_magic` remains disabled, quote and factoid rows are
unchanged, and one verified bounded Short Content repository revision remains.

The source-only package contacts no production service and performs no
Partyline mutation. It fingerprints the complete development `plugin-data`
tree before applying documentation and executable contracts, then requires the
same fingerprint immediately before commit. The development ledger is
therefore unchanged, and MB784 grants no new runtime authority. Operational
details and package-scoped rollback are recorded in
[`PLUGIN_V3_PRODUCTION_PORTFOLIO.md`](PLUGIN_V3_PRODUCTION_PORTFOLIO.md).

## MB785 production update acceptance

MB785 used the authenticated `update status` and `update now` IRC paths to
move nbot from `62820dc` (`3.6dev-20260924_144509`) to the reviewed MB784
source `7db72ea` (`3.6dev-20260924_204823`). Staged Perl syntax and startup
integrity passed before shutdown. The systemd contract remained
`Restart=always` plus `ExitType=cgroup`, durable status finished
`success/completed`, and the exact previous release was retained as
`/home/mediabot/mediabot_v3.229`.

After restart, all five packages were ready, fully permitted, enabled/on on
`#i/o` and at zero failures. The complete internal plugin-data tree was exact
in bytes, modes, ownership and stable timestamps. The boot ledger and retained
Short Content KV revision were byte-for-byte identical; quote and factoid data
were unchanged.

MB786 turns that live evidence into an isolated end-to-end regression. A local
temporary Git release and disposable bot exercise the real updater, including
a final shutdown write that must appear only because snapshotting happens after
the bot stops. The rehearsal contacts no production service, changes no
operator posture and grants no authority. The evidence and recovery boundary
are recorded in
[`PLUGIN_V3_UPDATE_ACCEPTANCE.md`](PLUGIN_V3_UPDATE_ACCEPTANCE.md).
