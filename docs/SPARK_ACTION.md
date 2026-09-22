# Spark action lane

`SparkAction` is a second, default-off channel capability for short Spark
micro-events driven by recent conversation momentum. It complements the
long-silence Spark lane; it does not replace it.

## Activation contract

An active micro-event requires both channel capabilities:

- `+Spark` keeps the main Spark feature enabled;
- `+SparkAction` authorizes the separate momentum lane.

Registering the capability does not enable it on an existing channel. The
MB709 foundation migration only adds the capability name to `CHANSET_LIST`.

It also requires both default-off process switches:

- `SPARK_SEND_ARMED=1` authorizes Spark delivery globally;
- `SPARK_ACTION_SEND_ARMED=1` authorizes this action lane specifically.

## Momentum repertoire

`stage_cue` is a contextual ambient action. After recent multi-human activity
enters a short breathing pause, the provider may produce one compact stage
direction tied to a concrete conversational detail. Mediabot is always the
only actor. The cue cannot name, address, quote, rank or assign actions to a
participant, ask a question, start a game, keep score or create a reward.

The model returns a plain action body. The guarded sender rejects control
characters, `/me`, CTCP markers and protocol-shaped output before constructing
the single CTCP ACTION frame itself. Generated text is never written to Spark
diagnostic logs.

`afterglow` uses the same authorization and pacing but sends an ordinary IRC
message: a short mock incident report, suspicious consequence, wrong-window
afterthought or deadpan epilogue tied to one concrete conversational detail.
It cannot name participants, ask for input or merely paraphrase the exchange.
The deterministic selector alternates the two families and avoids an immediate
repeat. A declined generation stays silent and consumes the current momentum
window; it never falls through to a second provider request.

The momentum policy considers a channel only after recent multi-human activity
has reached both participation thresholds and the conversation has entered a
short breathing pause. It rejects active games, another Spark event, pending
Wit work, flood suppression, stale activity, missing IRC truth, and either
disabled channel capability, unavailable AI, or either disabled process arm.
Any new public human line revokes an in-flight generation. All mutable gates
are checked again immediately before transport.

## Runtime defaults

The runtime reads these optional `main` configuration keys. Invalid or missing
values fail back to the bounded defaults shown here:

```ini
SPARK_ACTION_SEND_ARMED=0
SPARK_ACTION_ACTIVITY_WINDOW_SECONDS=600
SPARK_ACTION_MIN_HUMANS=3
SPARK_ACTION_MIN_LINES=6
SPARK_ACTION_MIN_PAUSE_SECONDS=45
SPARK_ACTION_MAX_PAUSE_SECONDS=180
SPARK_ACTION_PROBE_SECONDS=30
SPARK_ACTION_COOLDOWN_SECONDS=1200
```

`[SPARK_ACTION_CANDIDATE]`, `[SPARK_AI_DRYRUN]`, `[SPARK_SEND]` and
`[SPARK_EVENT]` expose bounded operational metadata only. A successful cue is
closed immediately as `delivered`; it never waits for or claims human
participation.

The observer keeps two independent bounds: a tiny text window for provider
context and a larger metadata-only activity window for audience measurement.
Commands, direct bot triggers and nicks listed in `main.BOT_NICKS` never enter
human context or participant counts. They instead create bot pressure, which
postpones unsolicited Spark work. The bot's own live nick is always classified
as automation even when `BOT_NICKS` is empty.

The stronger per-channel exclusions in `conversation.CHANNEL_BOTS` and
`conversation.CHANNEL_COMMANDS` run before this observer. Those lines create
neither human activity nor bot pressure and cannot start, advance, postpone or
close Spark or SparkAction work. This distinction is intentional: `BOT_NICKS`
models visible automation pressure, while the central barrier models traffic
that the whole interactive runtime must ignore.

Activity summaries expose human line rate, distinct-human count, a
recency-weighted effective audience, dominant-speaker share, bot-pressure
volume and quiet durations. Effective audience uses participation balance, so
one prolific speaker plus several occasional voices does not look like a
balanced group. Message text and nicknames do not cross the policy boundary.

## Audience-proportional pacing

The configured silence, probe, pause and cooldown values are reviewed
baselines. One pure policy maps activity metadata onto five ordered regimes and
scales those baselines centrally:

| Regime | Typical shape | Revival silence | Momentum delivery budget | Selection posture |
| --- | --- | ---: | ---: | --- |
| `empty` | no human evidence | 200% | 200% | no candidate |
| `solo` | one effective voice | 200% | 200% | autonomous Aside/Micro-scene; contextual Reaction/Callback when justified |
| `small` | two balanced voices | 150% | 150% | patient autonomous repertoire, no Portal |
| `social` | balanced conversation | 100% | 100% | reviewed baseline behavior |
| `crowded` | large balanced audience | 60% | 67% | shorter pauses and occasional Portal |

The effective-human count is authoritative, not the raw nick count. A speaker
holding at least 75% of the recency-weighted conversation demotes the policy by
one regime. Five balanced voices can reach `crowded` through sustained human
cadence. Recent bot pressure remains a hard postponement gate rather than an
excuse to increase activity.

`solo` does not enable momentum actions. The long-silence lane may instead emit
an autonomous `aside` or `micro_scene`, even when the old conversation offers no
usable callback. These are one-line, self-contained interventions: no question,
vote, score, named target or expected response. Reaction and Callback remain
available when at least three clean context lines offer a real hook. Portal and
source-backed stories remain unavailable to a single effective voice. An offline replay against anonymized
channel histories fixes this at the orchestrator boundary: two raw nicks do not
enable momentum when speaker dominance still classifies the room as `solo`.
Small momentum accepts a real two-human exchange with a proportionally lower
line threshold but then consumes a longer budget. Crowded momentum requires
more lines, recognizes a shorter breathing pause and returns its budget sooner.

The budget is channel-wide. A delivered SparkAction installs the same pacing
deadline seen by the long-silence Spark lane; the existing Spark event-state
cooldown continues to block SparkAction in the other direction. Candidate logs
include the bounded regime and applied pacing values, never text or nicknames.
No new configuration key is required.

## Long-silence repertoire

`aside` behaves like a quiet regular who finally drops one dry observation: a
mock status, a note about the atmosphere, or an absurd conclusion that makes
the room feel inhabited. `micro_scene` adds a compact visual gag with at most
two beats. Both are autonomous and may use recent context as inspiration, but
neither fabricates channel history or waits for participation.

Reaction and Callback keep their stricter contextual role. Portal remains a
rare collaborative option only for a sufficiently social room. The old
forced-choice and one-word collection families are retained solely so an event
already present during a rolling update can be decoded safely; the selector
marks them retired and cannot start a new one.

## Participation outcomes

Interactive event families retain explicit response contracts. Ambient
content closes as `delivered` immediately after successful transport; it is
not recorded as human engagement, does not wait for an unrelated channel line,
and does not reset the interactive miss streak.
