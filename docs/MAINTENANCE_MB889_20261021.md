# MB889 — Isolate Chromium subprocess ownership

## Responsibility and boundaries

`Mediabot::External::URL` mixed URL dispatch and provider metadata with a
Chromium subprocess driver: executable arguments, profiles, nonblocking pipe
draining, deadlines, signal escalation and decoding. The driver serves multiple
provider paths, including the Apple Music fallback through the legacy URL hook.
It now belongs to `Mediabot::External::Chromium`.

Three implementations move: `_fetch_url_chromium_dumpdom`,
`_wait_chromium_child` and `_decode_chromium_wait_status`. URL imports their
historical names as aliases to the owner. Its seventeen optional exports remain
unchanged. External imports the fetch function directly from Chromium and
retains its thirty-three default exports. Existing provider calls and dynamic
URL hook overrides remain in their current modules.

URL shrinks from 1,761 to 1,457 lines. Its twenty-five remaining named function
bodies are byte-identical. The two moved wait/status helper bodies are also
byte-identical. Fetch changes only its two fixed path expressions to private
dependency functions returning the same `/usr/bin/chromium` executable and
`/tmp/mediabot-chromium` profile base. These functions permit isolated native
fixtures; they add no configuration setting or caller option.

The owner declares its own Encode, process, select, fcntl, sleep and POSIX
dependencies and UTF-8 source handling. It loads independently of URL, Helpers,
the External facade and AI providers. URL drops six browser-only imports.

## Preserved behaviour

- The existing absolute HTTP(S) prefix guard still executes before executable
  or profile IO. The command remains an argv list with the URL last.
- The fixed defaults, configuration clamps, caller options, Chromium flags,
  throwaway profile naming and ten-minute opportunistic purge are unchanged.
- Both nonblocking pipes are drained together. Existing retention rules and
  diagnostic clipping are preserved; this round does not redefine output caps.
- The original request deadline also bounds waiting after both pipes close.
  TERM/KILL escalation and child reaping retain their original algorithms and
  time source. A signal cannot be decoded as exit-code success.
- Successful UTF-8 DOM decoding, invalid-UTF-8 raw-buffer fallback, unsuccessful
  or empty output, diagnostics and return values retain their contracts.
- Provider metadata, HTTP/browser fallback order, routing, chansets, cache keys,
  pending requests, workers and IRC output remain unchanged.

The driver remains synchronous. Callers retain responsibility for their
existing worker dispatch. It is not a new generic HTTP client, URL validation
framework, browser security policy or asynchronous process engine.

## Validation without growing the case catalogue

Five existing cases follow the new source owner or include its encoding policy.
The historical wait-status test now imports and executes canonical helpers in
its fresh subprocess, rather than compiling copied function bodies there.
The existing Chromium case gains thirteen assertions and one shared fixture:

- Four fresh-interpreter load orders check independence, default paths and
  owner/legacy/facade coderef identity.
- A fresh native probe reports eight checks plus its completion assertion:
  argv and successful Unicode DOM, stderr larger than a pipe buffer, nonzero
  exit, signal diagnostics, empty success, invalid UTF-8, post-EOF TERM/KILL
  cleanup and actual unsafe-argument refusal before any process/profile IO.
- The fake executable and profile base both live under an automatically
  cleaned private temporary directory. The actual open3/select/read/wait/kill
  implementation runs. No installed Chromium, public network, bot restart or
  live database is used. Process-global SIGCHLD state from unrelated cases is
  avoided by running these probes in a fresh interpreter.

The targeted twenty-file group passes **539/539 assertions**. The default case
catalogue remains 1,156 files. Generic module checks also inspect the new owner.
Complete-suite results, before/after comparisons, installer rehearsal and local
environment limitations are recorded in the delivery's qualification report.

No SQL statement, database schema, migration, private configuration, VERSION,
runtime service, queue, sender, test runner or audit implementation is changed.
The server installer requires the full unfiltered suite, all security invariants
and startup integrity to pass; it accepts no failing test.
