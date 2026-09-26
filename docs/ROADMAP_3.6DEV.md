# Mediabot 3.6dev development roadmap

This is the working order for the development line after MB787. Stable 3.5
remains the published version. There is no scheduled 3.7 release, target date,
release tag or production upgrade in this roadmap. The MB787 Debian 13 and
stable-3.5 migration gates remain technical compatibility evidence; passing
them does not decide when to publish.

The [3.5 roadmap](ROADMAP_3.5.md) records completed release work. New work
below is accepted in small, reversible steps on `3.6dev`, with source tests
before any separately approved change to the nbot `#i/o` instance.

## Next work, in order

| Step | Development work | Evidence needed before proceeding |
| --- | --- | --- |
| 1. Establish the `#i/o` baseline | Review the current pyDuckHunt commands and bot identities against [`CONVERSATION_EXCLUSIONS.md`](CONVERSATION_EXCLUSIONS.md); inspect recent `mediabot.log` and existing exclusion diagnostics. Correct the documented command list or scoped tests if the external bot changed. | A reviewed list of exact commands and senders; ordinary conversation still enters the normal pipeline; excluded traffic produces no Hailo learning, Spark activity or URL preview. No private message text in retained evidence. |
| 2. Exercise Hailo separately | Inspect each channel with `<prefix>hailo braininfo #channel`, then replay representative `#i/o` patterns against the existing per-channel Hailo controls: learning, direct replies and spontaneous chatter are independent. Verify exclusions, per-user and per-channel bounds, late revocation and provider fallback. | Targeted tests and a bounded observation showing no learning from commands, bots or the bot itself, no reply after authorization is removed, and no uncontrolled chatter. A later nbot pilot needs its own explicit channel policy and rollback. |
| 3. Measure Spark pacing | Reuse the audience policy and dry-run diagnostics with quiet, solo, small and busy channel samples. Check bot pressure, cooldowns, in-flight cancellation and the shared Spark/SparkAction delivery budget before considering a live send. | An anonymized replay plus tests showing no unsolicited output from excluded lines, one bounded candidate per eligible window and silence when a gate fails. Keep both send arms off during observation; any live `#i/o` trial is a separate, reversible operator decision. |
| 4. Investigate URL failures | Reproduce the reported TinyURL/news failures, including `blocked_destination` and rate limits, with controlled URLs. Identify the failing boundary before changing URL handling. | Tests proving unsafe destinations remain blocked, a failed shortening request can retain the original safe URL, and caching or retry cannot cause a request flood. No weakening of the destination guard to make a case pass. |
| 5. Preserve the production portfolio | Keep the five accepted API v3 packages and their nbot `#i/o` policies observable across ordinary updates. Extend tests only when a concrete regression appears in plugin state, updater ordering or restart restoration. | Doctor, permissions, policy and failure checks remain healthy; the boot ledger and plugin-data survive update and restart exactly as their contracts require. A new plugin or authority grant needs its own observe and rollback gate. |

MB792 prepares this pilot's answer-quality gate: the provider now knows whether
Hailo is answering a speaker or joining a conversation. Observe on development
whether it corrects writing errors and improves coherence without changing
negation, numbers or the draft's subject; provider failures retain the local
Hailo fallback. Do not infer semantic quality from unit tests alone.

MB793 makes the old outgoing script's narrow French typo fixes available even
when the provider fails; a real dev exchange is still needed to judge whether
the provider improves meaning without replacing Hailo's voice.

MB794 adds a private, per-channel post-editor outcome view so an operator can
see whether live replies were corrected, unchanged, locally fallen back or
dropped. Its memory-only counters reset on restart and contain no reply text;
they support, but cannot replace, a real development conversation.

Steps 2 and 3 use the baseline from step 1. The URL investigation can run
independently if a reproducible failure is available. A step may stay open
until its evidence exists; this table is an order of decisions, not a promise
to turn every capability on in production.

## Hailo brain maintenance

MB789 adds `<prefix>hailo help`, private
`<prefix>hailo braininfo #channel` for authenticated Master/Owner and
`<prefix>hailo savebrain #channel` for Owner. The prefix comes from
`main.MAIN_PROG_CMD_CHAR`. Inspection never creates an absent brain; saving
only persists an existing one. `hailo_status` also requires a channel when
called privately. The [maintenance crosswalk](HAILO_BRAIN_MAINTENANCE.md)
compares the MegaHAL operator commands with Hailo's actual behavior.
MB794 adds Master/Owner `<prefix>hailo edits #channel` for private runtime
counts without opening or seeding the channel brain.

MB790 presents the channel's brain state, readable Hailo counts and effective
policy in private notices. The percentages shown are configured base rates;
actual replies also depend on traffic and other guards. `hailo_status` keeps
its existing compact machine-readable output.

`forget` and `forgetword` need an exact channel training corpus and a tested
isolated rebuild before they can truthfully erase learned material. Hailo 0.75
does not expose selective deletion, and an old brain does not retain its input
phrases. Do not substitute a reply filter, raw SQLite edit or complete reset
for selective forgetting.

## Acceptance and rollback

- Do development source work on `3.6dev`; run focused tests, the fast lane and
  one final full suite before a source commit. CI results must also be green
  before relying on a new qualification gate.
- Read `mediabot.log` first for application behavior. Use service status for
  lifecycle evidence. Do not infer a successful production pilot from a local
  rehearsal or from a green test suite.
- A production change needs one scoped proposal with a before-state record,
  an observable acceptance window and the exact reversal of its configuration
  or policy. Preserve the existing five-plugin posture unless that proposal
  expressly changes it.
- Revisit a future stable release only after the development work merits one
  and the operator makes a separate release decision. The procedures in
  [`RELEASING.md`](RELEASING.md) remain available without starting a release.
