# API v3 plugin operations

MB750 added a read-only operator view over the API v3 state that already
decides runtime behavior. MB751 added bounded, in-memory failure evidence.
MB752 adds a separate Owner-only action for exact resource/channel containment;
it does not turn evidence into automatic remediation. MB754 adds no Partyline
mutation: its quote-command adoption uses the existing lifecycle, permission
and per-channel policy controls and remains inactive by default.

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
