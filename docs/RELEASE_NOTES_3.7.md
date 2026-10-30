# Mediabot 3.7 — The Next Chapter of the Grimoire 📖🪄

**Draft for review. Release decision pending. The published stable remains
3.5; this document creates no release, tag or deployment.**

The proposed 3.7 brings the 3.6dev line together around a more observable IRC
bot, an extensible Perl plugin platform and clearer behavior when operations
fail. This is a summary of source changes, not proof that every optional
feature is enabled on every instance.

## What is ready in source

- **A substantial plugin example:** the Perl "mot le plus long" game uses a
  core-owned asynchronous dictionary solver, accepts bare words, enforces a
  strictly increasing round record and closes a round immediately at the
  dictionary maximum. Persistent total/weekly scores, rankings and a single
  optimal-word bonus demonstrate the scoped storage and scheduler boundaries.
- **API v3 operations:** explicit capabilities, per-channel off/observe/on
  policy, owned jobs/events, bounded failure evidence and saved operator
  posture. The updater preserves plugin state across release rotation.
  **API v3 remains experimental**, with explicit activation and existing API
  v2 compatibility retained; this release does not promise a frozen new API.
- **French Trivia alongside English:** a separate local 6,044-question French
  catalog, while English keeps Open Trivia DB. Existing score storage remains
  shared. The archived French data retains its own attribution and CC BY-SA
  4.0 license in `Mediabot/Games/data/`; it is not generated translation.
- **Richer link previews:** dedicated opt-in Reddit and MixCloud handling,
  including Mixcloud shows and general creator profiles, plus fixes to music,
  feed and media parsing. External work stays bounded and asynchronous where
  required by its runtime path.
- **Channel administration and memory:** private channel diagnostics with
  scoped mbweb projections, conversation profiles, linked memory searches,
  a minimal plugin workshop and a documented first-channel walkthrough.
- **Reliability fixes:** Partyline UTF-8 output, IRC text budgets, plugin JSON
  persistence and duplicate-store handling, HTTP redirect budgets, expired
  mute cleanup, channel-case consistency and confirmed database read/write
  outcomes. Failures should not be reported as fabricated empty successes.

The complete history remains in `CHANGELOG.md`. Optional features keep their
existing opt-in gates; source installation does not enable a channel or grant
a plugin new authority.

## Install and upgrade

The reference installation path is Debian 13 with the repository's dependency
installer and `./configure`. An existing installation follows
`install/deploy_update.sh`, configuration synchronization and the authoritative
migration order in `install/migrations/README.md`. Never import the fresh
`install/mediabot.sql` over an existing database.

The 3.7 gate starts from the actual annotated stable 3.5 tag and retains its
released migrations unchanged. It checks the exact migration inventory and
order, strict drift and, in disposable Debian CI, logical rollback followed by
deterministic reapplication. A deployment also preserves private configuration,
plugin posture, scores and other configured runtime state. A code rollback is
not a database rollback; retain both before changing an installed instance.

The longest-word dictionary is optional and separate: database **DICT**, table
**DICT**, read-only runtime access. Its source dump is not redistributed or
automatically imported. See `LONGEST_WORD_PLUGIN.md` before enabling the game.
French Trivia needs no SQL import; its catalog is shipped with its data license.

## Qualification and limits

Complete the checks in [the acceptance sheet](RELEASE_ACCEPTANCE_3.7.md) on one
identified candidate. Both CI workflows, Perl/Node tests, audits, reproducible
archives and real operator observations are separate evidence. Test totals
alone do not certify IRC reconnection, web authorization or operational
stability. Provider availability and third-party data freshness remain external
dependencies; the French catalog is the documented 2022 archival selection.

No new production rollout, plugin activation, broad refactor or additional
feature is part of this preparation. Add the actual accepted commit, dates,
results and known limitations before converting these notes to published ones.
