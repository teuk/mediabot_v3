# API v3 plugin operations

MB750 added a read-only operator view over the API v3 state that already
decides runtime behavior. MB751 adds bounded, in-memory failure evidence. The
four views answer different questions without changing plugin lifecycle,
capability grants or channel policy.

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
| `limited` | package is enabled on a channel but one or more requested capabilities are not effective |
| `ready` | package is enabled, has an active channel and every requested capability is effective |

The report is diagnostic, not a health promise about an external endpoint or
database. MB751 adds an aggregate failure line, but previous failures do not
change the deterministic `inactive`, `limited` or `ready` decision.

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

`doctor`, `failures`, `permissions` and `why` are available to authenticated
Partyline readers, like `info`. They return only bounded scalar snapshots and
never expose the plugin object, `PluginContext`, service facades, database
handles, paths or secrets. They do not enable, disable, load, unload, change
policy, quarantine, reset history or clear data. Existing mutation commands
retain their Owner/Master gates.

MB751 deliberately stops at evidence. Automatic quarantine and a reviewed
reset path require a separate milestone because they change live behavior.
