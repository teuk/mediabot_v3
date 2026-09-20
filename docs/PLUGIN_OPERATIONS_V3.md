# API v3 plugin operations

MB750 adds a read-only operator view over the API v3 state that already decides
runtime behavior. It answers three different questions without changing plugin
lifecycle, capability grants or channel policy.

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
database. Existing failure counters and logs remain the source for transient
runtime failures.

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

`doctor`, `permissions` and `why` are available to authenticated Partyline
readers, like `info`. They return only bounded scalar snapshots and never expose
the plugin object, `PluginContext`, service facades, database handles, paths or
secrets. They do not enable, disable, load, unload, change policy, quarantine or
clear data. Existing mutation commands retain their Owner/Master gates.

MB750 deliberately stops at explanation. Automatic quarantine and a reviewed
reset path require a separate milestone because they change live behavior.
