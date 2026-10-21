# MB876 — separate YouTube, weather and Fortnite implementations

Base: `snap_mediabot_v3_teuk_20261021_124810.zip`, after MB875,
`3.6dev-20261021_104753`.

## Why extract these features

`Mediabot/External/YouTube.pm` held 1,727 lines and three distinct features:
video metadata/search, wttr.in weather and authenticated Fortnite statistics.
The shared byte-safe URL encoder served weather and YouTube search. Copied
headings also described URL, Instagram and Claude implementations that had
already moved elsewhere.

The weather and Fortnite bodies are separate enough to extract without
redesigning their transport, parsing or command policies. The refactor gives
each feature one implementation owner and reduces YouTube.pm to 1,311 lines.
Its remaining video metadata, formatting and search code belongs together;
this round does not introduce further service layers or combine transports.

| Module | Responsibility | Lines after extraction |
| --- | --- | ---: |
| `External/YouTube.pm` | Video identity, metadata, IRC rendering and search | 1,311 |
| `External/Weather.pm` | Weather command, location normalization, cache and provider fallback | 147 |
| `External/Fortnite.pm` | Fortnite account lookup, access checks, API parsing and rendering | 251 |
| `External/URLCodec.pm` | Shared byte-safe `_uri_escape_bytes` implementation | 23 |

## Existing entry points remain usable

`Mediabot::External` imports weather and Fortnite directly from their new
owners. Its public export list is unchanged, so the built-in commands keep
their current names, signatures and dispatch. Weather, meteo and f require
no caller migration or configuration change.

YouTube.pm imports the former weather/Fortnite symbols as compatibility
aliases and retains its existing optional export list. Existing imports and
fully qualified calls through `Mediabot::External::YouTube` therefore keep
working. These aliases point to the same implementation as the owner and
facade; there is no second copy or compatibility-specific business logic.
The old fully qualified URL encoder remains available through its import.

New code should use the owner module or the public External facade rather
than adding another weather/Fortnite dependency on YouTube.pm. No removal
of the compatibility symbols is scheduled by this patch.

## Preserve behavior and test ownership

All 25 function definitions from the original YouTube.pm were compared as
exact byte substrings with their final owners. Only their placement and
imports change. The three new modules declare their own dependencies and
UTF-8 source handling. YouTube drops its now-unused String::IRC and Encode
imports and the unrelated copied headings.

Weather retains the same cache object and keys, 180-second freshness,
900-second outage reuse, 200-entry bound, location escaping, channel gating,
four-second verified-TLS request and original targets. Fortnite retains its
queries, access checks, single request, ten-second verified TLS, mode order,
MB875 response contracts and exact display formatting.

Historical static tests now read the module that owns the implementation.
The owner-map test follows the split and adds the weather and float-format
cases. The search syntax regression finds the command's own closing brace
instead of relying on the unrelated following Fortnite comment. The source
encoding inventory includes the two new feature modules. Existing checks
are retained, and no test file is removed or excluded.

New regressions:

- `1296_mb876_external_module_boundaries.t`: seven fresh-interpreter loads,
  import order, independent feature loading, legacy imports, shared code
  references and exact character/UTF-8-byte URL escaping.
- `1297_mb876_external_entrypoint_compatibility.t`: owner/facade/legacy/builtin
  Fortnite paths with real Context and in-memory SQLite queries; success,
  malformed status/leaves and API errors. Compare output, return value,
  routing, audit and HTTP options. Exercise five weather entry points against
  one shared cache, including Unicode text and failed refresh behavior.

The shared MB875 Fortnite test fixture accepts an optional handler so the
same offline inputs can exercise each entry. Its existing default remains
the built-in f handler; the MB875 regressions retain that execution path.
No API, IRC server or production database is contacted by the new tests.

No schema, migration, private configuration, VERSION, service deployment,
HTTP policy or test-runner change is included. Executed results and local
environment limitations are recorded in the package's `QUALIFICATION.md`.
