# Offline Spark replay (MB798)

MB798 takes an operator-supplied, anonymized JSON Lines history and replays
the production conversation exclusion boundary, Spark observer, state and
orchestrator with a virtual monotonic clock. The tool constructs no generator,
provider, IRC connection or sender. Candidate results are policy evidence only.
It changes neither process send arm nor channel capability.

Run from the Mediabot source directory on development:

```sh
perl tools/mb_spark_replay.pl \
  --config tools/fixtures/mb798_spark_replay.conf \
  --input tools/fixtures/mb798_spark_replay.jsonl \
  --channel '#room' --bot-nick Mediabot
```

Supply a **copy of the target instance's config** when testing its exclusions;
the included fixture is synthetic and says nothing about `nbot` or `#i/o`.
The input is a sequence of at most 256 JSON objects, one per line, sorted by
integer `at` seconds from 0 to 604800. A public line has `type:"line"`,
`nick` and `message` (at most 240 characters). Set `from_bot:1` only for
nonexcluded automation that should contribute bot pressure. A probe has
`type:"probe"` and `at`. Give nicknames generic aliases and replace content
with benign sample phrases while preserving command or address prefixes;
never paste private chat logs. The tool emits decisions and counters, no input
messages or nicks, and fails on malformed or oversized input.

The replay evaluates both Spark policy lanes at each probe and records any
second momentum candidate in the same unchanged human activity window as an
error (exit 2). Excluded lines reach neither observer nor flood guard. A
nonexcluded bot line still delays momentum through bot pressure. No generated
text is assessed here: this tool cannot demonstrate live delivery, provider
quality or actual runtime reloads. A change to nbot requires separate evidence
and authorization.
