# Hailo brain operations: MegaHAL Interface crosswalk

This describes the MB789 brain inspection and safe per-channel save, plus later maintenance
design. Only commands marked as delivered are available in Mediabot.
The reference is MenzAgitat's **Interface MegaHAL 4.1.0**, including the
author's published Tcl command settings and script description:

- <https://forum.eggdrop.fr/Interface-MegaHAL-(version-actuelle-410)-t-706-8.html>
- <https://scripts.eggdrop.fr/details-interface+megahal-s134.html>

Mediabot uses Perl Hailo 0.75 and a separate SQLite brain per network/channel.
It does not run that Tcl or the MegaHAL C module. The Hailo API documents
`learn`, `train`, `reply`, `save` and `stats`; `stats` reports tokens,
expressions and links in both directions, not MegaHAL's association-node
count. Learning is lossy and there is no documented public `forget` API:
<https://metacpan.org/pod/Hailo>.

## What exists in Mediabot today

- `+Hailo`, `+HailoLearn`, `+HailoRespond` and `+HailoChatter` are independent
  channel policy switches; `hailo_chatter` controls the chatter ratio. The
`hailo_status` and the MB789 `<prefix>hailo braininfo #channel` command show
  channel-specific, bounded Hailo counters. `hailo_status` now requires a
  channel when called privately; it no longer resolves the last opened brain.
  The command uses Mediabot's configured public prefix, requires an
  authenticated Master or Owner, replies privately, reports policy and file
  size, and does not open or seed an absent channel brain.
- `<prefix>hailo help` lists the available subcommands. Owner-only
  `<prefix>hailo savebrain #channel` persists one existing channel brain,
  answers privately, and refuses absent or unsafe brain paths.
- MB794 adds Master/Owner `<prefix>hailo edits #channel`: two private notices
  show that channel's accepted provider edits, unchanged replies, local
  fallbacks, dropped work and current queue/in-flight counts. The bounded
  counters live in process memory since startup, may evict older channel
  histories, and never contain draft text or open a brain.
- MB796 adds Master/Owner `<prefix>hailo check #channel ambient|mention|chatter
  <texte>`: a private, read-only policy rehearsal for the authenticated
  operator's own text. It inspects configured conversation exclusions, Hailo
  normalization and current learn/reply gates without opening a brain,
  training, making a provider request or sending to a channel. A possible
  mention reply still needs its random draw; chatter traffic and late delivery
  are not simulated. The sample text is not echoed in the notices.
- MB790 makes `hailo braininfo` readable in three or four short private
  notices. It describes the brain's saved file size, Hailo's four counters,
  and the effective learning bounds, mention-reply percentage and channel
  chatter base ratio where configured. The chatter ratio is adapted to channel
  traffic; other runtime checks can also suppress learning or delivery. These
  counters are not MegaHAL nodes, remembered word counts or an archive of
  original messages. `hailo_status` retains its compact technical line.
- MB791 adds the same restrained IRC foreground accents used elsewhere in
  Mediabot: orange/bold for Hailo, underlined section labels, cyan figures,
  green for enabled, red for disabled and amber for missing information.
  Clients that ignore formatting still see the complete text. The read-only
  operator notices remain within Mediabot's 400-byte send budget; the compact
  `hailo_status` output keeps its original bytes.
- `BrainRegistry` maps the RFC1459-casemapped channel and network to a private
  SHA-256-derived `.brn` path, seeds a new channel brain once from an old root
  brain if available, saves on eviction and exposes `save_all`. It does not
  provide per-phrase provenance, selective deletion or a replacement protocol.
- `HAILO_IGNORE_NICKS` and the shared conversation exclusions keep known bot
  traffic out of learning; the reply queue and post-editor have late policy
  checks. These are prevention and delivery controls, not retrospective
  deletion of already learned content.

## Command inventory and decision

Tcl command names below omit its configurable public prefix (`.` by default).
`<prefix>hailo help`, `<prefix>hailo braininfo #channel` and
`<prefix>hailo savebrain #channel` are delivered in MB789;
`<prefix>hailo edits #channel` is delivered in MB794 and private
`<prefix>hailo check #channel <mode> <texte>` in MB796. `<prefix>` is
`main.MAIN_PROG_CMD_CHAR` (usually `!`); Partyline keeps `.` for any separate
operator commands. The `<prefix>hailo forget` and `<prefix>hailo forgetword`
examples remain **proposed**, without callable mutators.
A channel is always explicit for brain operations. This is an inventory of the Tcl 4.1.0 command
settings, not a promise to port MegaHAL internals one for one.

| MenzAgitat Tcl | Purpose | Mediabot decision |
| --- | --- | --- |
| `aide_megahal`, `megaver` | Help and engine/interface version | MB789 delivers `<prefix>hailo help`; braininfo identifies SQLite. An exact Hailo engine version is not yet reported. |
| `megahal`, `learn`, `respond`, `chatter` | Channel master, learning, direct replies, free chatter | Already modeled by the four Hailo chansets; document/query their effective state, keeping policy changes in the existing authorized channel path. |
| `replyrate`, `keyreplyrate` | Free-chat and addressed-reply probabilities | `hailo_chatter` manages the former; MB790 braininfo shows the configured `HAILO_KEY_REPLY_RATE` as a base rate. MB796 check marks a pending random draw without consuming it. |
| `megahal_status`, `braininfo` | Channel switches and brain metrics | MB789/790: `<prefix>hailo braininfo #channel` reports the four Hailo counters, readable on-disk size, brain state, effective policy and applicable rates in short private notices. MB794 `<prefix>hailo edits #channel` separately reports transient post-editor outcomes; these are neither MegaHAL node counts nor retained training text. |
| `countword`, `seekstatement` | Count a word; find a learned statement | Design bounded, read-only Hailo queries only if the stored representation supports truthful semantics. An occurrence of a token or transition does not prove an original sentence is retained verbatim. Mark uncertainty rather than invent a match. |
| `forget`, `forgetword` | Remove a phrase; remove learned phrases containing a word | Priority: `<prefix>hailo forget #channel <exact phrase>` and `<prefix>hailo forgetword #channel <word>`. Implement only with proven selective deletion or verified rebuild of that channel from an authorized source. No fuzzy nearest-phrase deletion or substring match. See the contract below. |
| `savebrain`, `reloadbrain` | Save or reload a brain | MB789: Owner-only `savebrain #channel` persists an existing channel brain. Replacement/reload still requires a coordinated switch; do not swap a live SQLite file while Hailo or a pending reply is using it. |
| `learnfile` | Train from a file | Later, Owner-only, allowlisted local input with size and line limits, same exclusions and channel scope; avoid accepting arbitrary paths via IRC. |
| `reloadphrases` | Reload MegaHAL `.phr` file | No direct Hailo equivalent; evaluate an explicit, validated channel corpus import only if there is a real use case. |
| `trimbrain` | Bound association nodes | No direct node-count API; evaluate offline rebuild or a supported Hailo limit. Do not edit SQLite link counts to approximate MegaHAL trimming. |
| `lobotomy`, `restorebrain` | Reset and restore a brain | Later, explicit Owner-only per-channel backup/restore with validation and rollback. Never silently reseed a reset channel from the legacy root brain. |
| `memusage` | Estimate memory use | Report only measurable file/process facts, clearly scoped; avoid claiming an exact per-brain memory figure from process-wide RSS. |
| `treesize`, `viewbranch`, `getwordsymbol` | Inspect MegaHAL trees and word symbols | MegaHAL-specific model. If needed, offer bounded Hailo token/link diagnostics with an authenticated operator surface and documented different semantics. |
| `make_words`, `debug_output`, `moulinex_in`, `moulinex_out` | Inspect tokenization, output and Tcl text filters | MB793 brings three French output typo/punctuation fixes into the actual reply path. MB796 privately rehearses exclusions and Hailo learn/reply policy without sending; provider output and the wider pipeline are not simulated. |
| Force prefixes `&`, `%`, `~`, `$` | Override learn/reply combinations | Present in Mediabot's local policy engine, unavailable as public controls until authenticated privilege mapping exists. |

The Tcl also has a permission-gated request to quiet the bot temporarily,
automatic save/backup scheduling and multi-level Partyline debugging. These
should be compared against Mediabot's existing channel switches, queue
diagnostics, persistence and logs rather than copied as public control text.

## Proposed selective-forgetting contract

1. **Discovery:** identify which normalized training records, if any, can be
   associated with a single Hailo channel brain. Check whether the current
   `.brn` and any authorized source corpus allow exact reconstruction. Hailo's
   lossy model alone cannot be treated as a transcript. Decide retention and
   access policy before introducing any future per-channel training ledger.
2. **Preview:** Owner invokes an explicit target channel. Normalize the input
   with the same tested tokenizer as learning. Show a bounded count and
   ambiguity status privately; do not include the matched raw lines in logs
   or routine public output. `forget` targets one exact normalized training
   phrase, never the Tcl's closest-match guess. `forgetword` targets a whole
   token and every covered training record containing it.
3. **Apply:** stop new learning and delivery for that channel; drain or revoke
   pending work. Preserve a consistent, private backup of the channel brain
   and any corpus used for rebuilding. Build and integrity-check a replacement
   in isolation, excluding precisely the target records, then switch it in
   under a generation gate. Restart/eviction must not restore the deleted
   material from either a stale live object or the legacy seed.
4. **Verify:** compare before/after counts, check absence under the defined
   normalized query, preserve unrelated training and another channel, restart
   and query again, and prove a rollback restores the original brain. Report
   the affected record count and outcome without publishing learned text.
5. **Legacy limitation:** if no faithful training corpus or validated selective
   algorithm exists for an old brain, return `selective forgetting unavailable`
   with a channel-specific backup/rebuild option. A full reset is a separate
   operation and must never be called a successful `forget` or `forgetword`.
   A forgotten word can be learned again; a future-learning block is a
   separate, explicit channel policy decision.

MB789 delivers `braininfo`, `help` and `savebrain`. Next, write the
feasibility/fixture tests for exact forgetting. Ship actual mutators only after the above contract passes on a
throwaway brain, including interruption and restart cases. Then use the
regular targeted tests, fast lane and single final full suite before commit;
observe any nbot `#i/o` pilot separately with a before-state and reversal.
