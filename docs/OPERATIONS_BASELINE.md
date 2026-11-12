# Operational baseline — MB1255

Source baseline: `0cddd3e38c60559817ceac4ce1dd8c2e859d663b` (committed MB1254), matched against every tracked
file of the supplied 2026-11-12 16:07:55 snapshot. This is a source-backed inventory,
not a live incident report or a claim that every declared metric is enabled.
No runtime log samples, Prometheus series or full host acceptance transcript were
supplied with this snapshot. Do not invent failure rates, latency percentiles,
resource counts or a numerical host test total from the commit alone.

## Existing observation surfaces

| Surface | Existing evidence in code | Interpretation / limit |
| --- | --- | --- |
| Worker console | [TaskConsole](../Mediabot/Partyline/TaskConsole.pm): `ps workers`, `show <id>` inside the internal console; task ID, PID, elapsed time, timeout and progress count. | Live logical tasks, not a retained history or census of uncollected children. Inspection is separate from cancellation. |
| Scheduler console | Same console exposes task duration, maximum duration, ticks and callback exceptions. | An enabled schedule and an already-started worker have different lifetimes. |
| Core health | [Metrics](../Mediabot/Metrics.pm): `mediabot_irc_connected`, `mediabot_db_up`, `mediabot_loop_stalls_total`, `mediabot_privmsg_processing_seconds`. | Definitions exist; verify the instance actually exports them before building alert rules. |
| Achievement workload | Metrics declares pending queue, inflight worker, dropped work, results and timeout counters. | Family-specific observations; do not treat them as generic AsyncWorker totals. |
| Output pressure | Antiflood block/mute/expiry counters; Hailo post-edit queue depth and inflight metrics. | Counters distinguish some outcomes but do not provide a general queue-age or delivery-latency view. |
| Generic lifecycle | [AsyncWorker](../Mediabot/AsyncWorker.pm) classifies timeout, cancellation, signal, exit, setup and protocol/size failure. MB1254 tracks physical children separately and diagnoses incomplete final cleanup. | A result can be finalized before physical exit is confirmed. No new metrics or callback behavior is introduced here. |
| AI failure boundary | [AI::Client](../Mediabot/AI/Client.pm) previously collapsed failed worker envelopes to `worker_failed` without retaining their cause at this boundary. | A timeout and a process signal became indistinguishable to the consumer. This is the first concrete observation gap selected below. |

## First correction: preserve a safe worker diagnosis in logs

MB1255 adds one best-effort level-1 log entry when the first terminal AI worker
failure is accepted and the loop owner supplies a logger. Example:

```text
AI worker failure code=worker_timeout stage=timeout
```

Both fields use closed allowlists. Unknown error names become `worker_failed`,
unknown stages become `unknown`, and malformed successful envelopes are labelled
`invalid_result`. No provider/model, prompt, answer, child detail, URL, credential,
PID or user/channel identifier is copied into this diagnostic.

The existing public `{ok => 0, error => 'worker_failed', attempted => []}` remains
unchanged. Provider-level failures carried inside a valid worker result retain
their own categories (including response_too_large) and are not logged as worker
transport failures. Successful answers are unchanged. Logger absence or failure
cannot block completion, and duplicate/reentrant completion cannot duplicate logs
or consumer delivery. No retry, timeout or fallback policy changes.

The existing case 1285 now tests these boundaries using the real Client submission
path and an injected worker completion. It passes 118 assertions; the unchanged
baseline fails the new diagnostic checks. The four locally available client cases
919/1028/1284/1285 pass 294 assertions. Broader case 1436 stops because the local
Hailo dependency is absent; this is not a passing test. The package requires that
case and one full suite on the installed host before commit/push.

## Next measurements and decision rule

1. On the normally activated version, inspect existing logical worker/scheduler
   state and confirm which health metrics the development instance exports.
2. Count the fixed AI worker failure categories over an explicitly recorded period;
   distinguish timeouts from process/setup/protocol errors before proposing a fix.
   Absence of a line is not proof of success when the logger is missing/disabled.
3. For one recurring category, reproduce a concrete cause with controlled inputs.
   Keep normal result delivery and timeout/fallback contracts covered. Do not hide
   an error with retries or globally larger timeouts.
4. Measure before/after under comparable conditions. Introduce a new metric only
   if the existing surfaces cannot answer a specific operational question.

The architecture chapter has no new planned extraction. This operational chapter
starts with one evidence-backed logging correction and awaits actual measurements
before choosing the next runtime defect. No service restart, schema or deployment
configuration change is part of MB1255.
