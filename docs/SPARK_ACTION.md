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

## First action family

`stage_cue` is a contextual ambient action. After recent multi-human activity
enters a short breathing pause, the provider may produce one compact stage
direction tied to a concrete conversational detail. Mediabot is always the
only actor. The cue cannot name, address, quote, rank or assign actions to a
participant, ask a question, start a game, keep score or create a reward.

The model returns a plain action body. The guarded sender rejects control
characters, `/me`, CTCP markers and protocol-shaped output before constructing
the single CTCP ACTION frame itself. Generated text is never written to Spark
diagnostic logs.

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

Activity summaries expose only line count, distinct-human count, the last
human timestamp, and the derived quiet duration. Message text and nicknames do
not cross the momentum policy boundary.

## Participation outcomes

Interactive event families retain explicit response contracts. Ambient
content closes as `delivered` immediately after successful transport; it is
not recorded as human engagement, does not wait for an unrelated channel line,
and does not reset the interactive miss streak.
