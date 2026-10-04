# Mediabot 3.6dev — development roadmap

Stable 3.5 remains published. There is no scheduled 3.7 release or production
upgrade. The operator considers the `#i/o` exclusion inventory and Hailo reply
observation complete for the current planning sequence. This decision does not
turn a development commit into an nbot deployment.

## Current position

| Area | Delivered | Current work |
| --- | --- | --- |
| Hailo | Channel brains, `braininfo`, `savebrain`, `edits`, policy `check`, and the development reply work through MB803. | MB805 rehearses backup and isolated rebuild with synthetic input. `forget` and `forgetword` still need an exact authorized corpus and a safe live replacement protocol. |
| Spark | MB798 offline replay uses the production exclusion, observer and pacing logic without a sender. | MB805 aligns replay's command prefix with its supplied configuration; measure anonymized `#i/o` windows before a separate live-send decision. |
| URLs | MB804 distinguishes DNS unavailability from a blocked RSS destination. A Journal du Geek probe returned HTTP 200 and a news item was announced on development. | Revisit TinyURL or RSS only with a reproducible failure; keep unsafe destinations blocked and safe original links usable. |
| mbweb | MB814 hardens current roles, session revocation, authenticated dashboards and quote channel visibility on the development source. | Validate the dev deployment, then improve channel/RSS/RandomQuote views before implementing a bounded local bot action bridge for writes. |
| API v3 plugins | Five packages are accepted with their nbot policies and the MB784/786 preservation contracts. | Recheck source contracts and live Doctor/policy/boot state after an upgrade; retain the existing rollback boundary. |

## Next sequence

1. **Selective Hailo maintenance.** Run the synthetic MB805 rehearsal on the
   development host. Determine whether a complete, authorized per-channel
   training corpus can be retained for future brains. Prove exact selection,
   interruption recovery, isolated rebuild, generation-gated switch, restart
   persistence and rollback before adding Owner-only `forget` or `forgetword`.
   An old brain without a faithful corpus remains ineligible for selective
   deletion; a whole-brain reset is a different operation.
2. **Spark measurement.** Replay anonymized quiet, solo, small and busy windows
   using the target instance's configuration, including its actual command
   prefix. Require correct bot pressure and pacing, no excluded-line influence,
   and at most one momentum candidate in an unchanged human conversation
   window. A live send requires its own acceptance and rollback.
3. **Plugin and release maintenance.** Preserve all five API v3 packages,
   manifest capabilities, policies, boot ledger and business data after an
   upgrade. Keep Doctor and failures readable; run the existing MB784/786
   source contracts before a source commit. A future stable release needs a
   separate decision.
4. **URLs on evidence.** If a TinyURL/news failure recurs, record the exact
   failure class and test a controlled destination without weakening the
   destination guard or causing a retry flood.

## Source and runtime boundary

Run focused tests, the fast lane, then one visible full suite immediately
before each source commit. A dev restart does not change nbot. An offline
replay or synthetic brain proves only the behavior it exercises; nbot work
requires its own observed before-state, window and rollback.

## mbweb development sequence

Work first on the dev console. The first source round is MB814 authorization
and scoped reads, with the Node lane, focused Perl contracts, fast lane and
full suite before commit. Verify source/runtime convergence and the public
health endpoint, then check Owner and lower-level accounts on permitted and
non-permitted channels. Revoke a disposable test account and downgrade its role
without leaving privileged content accessible through the existing session.

Next, make navigation, instance identity, freshness and channel detail useful:
RSS feeds and pacing, RandomQuote state/frequency, complete chansets and the
accepted Hailo/Spark capability views. Separate desired persisted configuration
from confirmed runtime state.

A later write round should introduce named, bounded local actions handled by
Mediabot itself, with revalidated actor/channel rights, CSRF, explicit results,
rate limits and audit events. Start with RSS pacing and RandomQuote, then quote
management and selected chansets. A generic SQL editor, arbitrary partyline
command input and shell execution are outside this sequence.
