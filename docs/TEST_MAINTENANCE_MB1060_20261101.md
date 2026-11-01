# MB1060 — Stable Chromium fixtures and an approximate progress ETA

Base: MB1059 applied to `snap_mediabot_v3_teuk_20261101_135555.zip`.
The reported operator run stopped at Chromium case 703 before restart/commit.

## Chromium fixture

The exact `native signal termination preserves its stderr diagnostic` failure
is reproduced on the unchanged MB1059 helper by running its native probes with
`SIGTERM` ignored in the parent. Ignored dispositions survive exec. The old
signal child inherited IGNORE, so its self-sent TERM did not terminate it and
it fell through to `_exit(99)` instead of reporting signal 15.

The signal child now explicitly selects DEFAULT for TERM and writes its small
ASCII stderr diagnostic with syswrite before sending the actual signal. The
real native Chromium wrapper, actual pipes, process exit/status decoding and
signal assertions remain under test.

The one-second browser-fixture budget introduced in MB1059 is restored to two
seconds. The application wrapper uses integer `time()`, so a one-second budget
can leave almost no startup time near a second boundary. A deterministic native
clock-boundary probe reproduces ALARM with 1s and the real signal diagnostic
with 2s. The closed-pipe child still ignores TERM and must actually be killed
and reaped. No Chromium application timeout or implementation is changed.

## ETA with --progress

Example:

```
[=========>          ]  50% [600/1198 files | 18000 tests] | ETA ~00:02:30 | running: example.t
```

The estimate uses the elapsed monotonic time divided by completed files, times
the number of remaining selected files. It is recomputed at the existing
per-file progress updates; it is not a per-second countdown. Test durations
vary, so the `~` is intentional. It can fluctuate, especially near the start.

Before the first completed file, the display says `ETA ~--:--:--`. Completion
always says `ETA ~00:00:00`, including a run containing failed assertions. Failure
statuses, actual assertion totals and deferred failure diagnostics are unchanged.
Only --progress emits ETA. The existing normal, verbose, filtered and fast-lane
behavior remains. No timing history/cache, persisted results, extra timer,
signal handler or test parallelism is introduced.

The existing case 871 now checks the actual initial, intermediate and final ETA
output, terminal-line cleanup, selected-file counts, failure status and opt-in
behavior. Its assertion count does not grow; no new case file is added.

## Continuation and validation

The operator package expects MB1059 already applied, as in the reported run.
It recognizes the exact known MB1059 paths and final contents, including its
28 new files and intentional old-path deletions. On successful validation it
stages all still-untracked known files, so the native commit cannot accidentally
omit the moved regression sources. It also works when MB1059 was committed
separately. Other tracked changes are reported instead of being bundled in.

Full --progress, security/startup/inventory and diff checks still precede the
restart of dev. The installed native commit.sh retains its interactive review,
KEEP DELETIONS prompt, automatic 3.8dev VERSION and native push.

No application, schema, configuration, dependency, project README, production
service or private commit.sh is changed by this patch. See package
QUALIFICATION.md for the actual local results and environment limitations.
