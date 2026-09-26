# Mediabot 3.6dev — development roadmap

Stable 3.5 is published. The source work below stays on 3.6dev; there is no
scheduled 3.7 release or production upgrade. A green source suite qualifies
code, not the behavior of nbot on `#i/o`. The [3.5 roadmap](ROADMAP_3.5.md)
records previous release decisions.

## Current position

| Area | Delivered on development | Still needed |
| --- | --- | --- |
| Hailo brains | Per-channel persistence; private `braininfo`, `savebrain` and `edits` commands (MB789–794). | Real channel observation; selective forgetting needs a faithful corpus and an isolated rebuild. |
| Answer quality | Provider grammar/coherence request, local typo cleanup and semantic fallbacks (MB792–795). | Compare actual Hailo drafts and provider replies on development; counters alone cannot prove quality. |
| Hailo policy | MB796 adds private `hailo check #channel ambient|mention|chatter <texte>` for an operator's own text, without learning, opening a brain, submitting to a provider or sending to a channel. | Review actual pyDuckHunt command names and bot senders before using this on an nbot pilot. The check reports eligibility; randomness, traffic and late delivery remain separate. |
| Spark and URLs | Existing pacing guards and TinyURL destination checks. | Bounded Spark replay; reproduce `blocked_destination` and rate limit failures with safe URLs. |
| API v3 plugins | Five accepted packages and their existing nbot policies. | Preserve boot, policy and restart behavior across upgrades. |

## Next decisions

1. **Qualify `#i/o` exclusions.** Compare the live pyDuckHunt command list and
   sender identities with [the exact exclusion contract](CONVERSATION_EXCLUSIONS.md)
   and recent `mediabot.log`. Update configuration and fixtures only after that
   comparison. Acceptance: an ordinary user line remains eligible; known bot
   lines, direct addresses and exact external commands never reach learning,
   Spark or URL preview. Keep message bodies out of retained diagnostics.
2. **Exercise Hailo on development.** Use private `hailo check` with ambient,
   mention and chatter samples; inspect `hailo braininfo` and `hailo edits`.
   Then observe actual provider output and late delivery after a policy change.
   Acceptance: no excluded learning, distinct learn/respond/chatter controls,
   bounded rates, no send after revocation, and replies whose meaning stays
   anchored to the Hailo draft. The preview does not replace live evidence.
3. **Measure Spark independently.** Replay quiet, solo, small and busy channel
   windows with both send arms disabled. Acceptance: at most one eligible
   candidate per window, correct bot pressure and cooldown decisions, and no
   output from excluded lines. A live send requires its own decision.
4. **Investigate URL failures.** Reproduce TinyURL/news `blocked_destination`
   and rate limit behavior with controlled URLs. Acceptance: destinations stay
   blocked when unsafe, safe originals survive a failed shortening attempt,
   and retries cannot flood a provider.
5. **Maintain plugin and release gates.** Recheck the five API v3 packages,
   Doctor, policy, boot ledger and plugin data after upgrades. A proposed nbot
   change needs its own before-state, observation window and exact rollback.
   Consider a future stable release only by a separate operator decision.

## Source gate and nbot boundary

Run targeted tests, the fast lane, then one visible full suite immediately
before each source commit. Use `mediabot.log` for application behavior and
systemd for service lifecycle. A dev restart never changes nbot. CI and live
observation are additional evidence before a separately scoped nbot pilot.

## Hailo maintenance still open

Delivered: Master/Owner can inspect a channel brain, view in-memory post-edit
outcomes and rehearse a sample policy decision; Owner can save an existing
brain. See the [command crosswalk](HAILO_BRAIN_MAINTENANCE.md) for exact
privileges and the separate MegaHAL semantics.

`forget` and `forgetword` are not implemented. Old Hailo brains do not retain
all training phrases, so an exact channel corpus and a tested isolated rebuild
are prerequisites for selective removal. Do not claim that a reply filter,
SQLite edit or whole-brain reset forgets an individual phrase.
