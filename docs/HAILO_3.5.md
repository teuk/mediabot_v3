# Hailo 3.5 architecture

Hailo modernization is a release gate for Mediabot 3.5. It is delivered as a
bounded pipeline, not as a replacement conversational model.

## Required behavior

1. Each IRC channel owns an independent durable Hailo brain.
2. A reply is generated from prior training before the triggering line is
   learned.
3. Learning and speaking are separately gated per channel.
4. Commands, pasted log prefixes, presentation controls, configured ignored
   nicks and messages emitted by Mediabot itself are not learned.
5. Nicknames are represented by reversible channel-local placeholders while
   Hailo processes text.
6. Reply and learning operations have short deadlines, per-user cooldowns and
   bounded queues.
7. Every accepted Hailo candidate is submitted to the common provider-neutral
   AI client for a constrained post-edit.
8. The post-editor considers the configured channel language, the triggering
   phrase language and the Hailo draft language.
9. Provider failure, timeout, malformed output or excessive rewriting falls
   back to the original sanitized Hailo candidate.
10. Metrics are aggregate and never contain nicknames, channel text or drafts.

## MegaHAL interface compatibility

Mediabot keeps the useful behavioural contract of `MegaHAL_Interface.tcl`
without loading Tcl or sharing one global brain:

- `Hailo` is the per-channel master switch;
- `HailoLearn` controls learning independently;
- `HailoRespond` controls replies to the bot nick or another explicit trigger;
- `HailoChatter` controls spontaneous replies independently;
- replies are generated before the triggering line is learned;
- copied-log prefixes, IRC presentation controls and commands are rejected
  from ordinary learning;
- `HAILO_IGNORE_NICKS` adds a reloadable comma-separated exclusion list using
  the IRC casemap; the live bot nick and the shared `BOT_NICKS` list are always
  excluded from context, activity, replies and learning;
- visible nicknames become reversible neutral placeholders inside Hailo;
- learning and replies have per-user cooldowns and a per-channel flood window;
- the provider-bound handoff has a bounded, expiring queue with one in-flight
  request per channel and a bounded process-wide concurrency ceiling.

Existing channels with `+Hailo` receive `+HailoLearn` and `+HailoRespond` from
the data-only migration, so the split introduces no silent opt-out. The four
historic force prefixes (`&`, `%`, `~`, `$`) exist in the local policy engine
but are not accepted from the public runtime until an authenticated privilege
bridge is delivered; treating them as public controls would be unsafe.

## Pipeline

```text
public line
  -> channel policy and learning guards
  -> input normalization and nick placeholders
  -> channel brain reply
  -> channel brain learn
  -> nickname rehydration and local candidate validation
  -> language decision and bounded recent context
  -> provider-neutral constrained post-edit
  -> lexical-anchor and IRC-output validation
  -> late channel/generation authorization
  -> non-blocking typing delay and IRC delivery
```

The Hailo draft is the creative anchor. The provider may repair spelling,
grammar and immediate coherence, but it may not invent a new generic answer.
A deterministic lexical-overlap and length-ratio gate enforces that boundary.

## Channel brain storage

Brains live in a private configured directory. A filename is derived from a
SHA-256 digest of the network and RFC1459-casemapped channel; raw channel names
are not used as paths. The directory is mode `0700`, brain files are mode
`0600`, symbolic-link targets are refused, and least-recently-used brains are
saved before bounded-memory eviction.

An existing root-level brain remains an immutable rollback source. On the first
use of a channel brain, it is copied as a seed so historical training is not
discarded. Channels diverge independently after that point. The generic
updater preserves both legacy root brains and the private channel-brain tree.

## Language policy

Supported channel policy languages are English, French and Spanish. A
confident triggering-phrase language may code-switch away from the configured
channel language. Otherwise the channel language is authoritative. The draft
language is recorded for validation and may confirm, but not silently override,
the channel policy.

Language detection is local, bounded and deterministic. Provider output is
never trusted to choose its own language without the explicit policy context.

## Provider boundary

The post-editor uses `Mediabot::AI::Client`; it owns no HTTP implementation,
credential lookup or provider-specific payload. Requests have a dedicated
purpose, short deadline, low temperature and small output budget. Recent
context is sanitized, kept to a few lines and passed as untrusted quotation.
The current trigger is not duplicated in that context, commands and known bots
are excluded, and the context exists only in bounded process memory.

The ignore decision is shared by the context observer and every local Hailo
turn. It is evaluated before the historical SQL exclusion cache, so a
`SIGHUP` or `.reloadconf` applies `HAILO_IGNORE_NICKS` immediately. IRC
`echo-message` cannot turn outgoing RSS announcements or any other Mediabot
output into training: the live bot identity is excluded even when it is absent
from both configuration lists and the SQL table.

The output contract is exactly one printable IRC-safe line. The following
conditions force the original candidate fallback:

- provider error or timeout;
- line break, control byte or oversized output;
- implausible expansion or contraction;
- loss of the candidate's learned lexical anchor.

Every normal Hailo reply enters this boundary. `HAILO_POST_EDIT_ENABLED=0` is
an explicit emergency provider kill switch: it retains the sanitized local
candidate and the same queue, expiry and late-authorization gates. An explicit
provider is strict; `auto` is the only mode allowed to cross to another
configured provider after failure.

Provider completion never grants permission to send. Immediately before IRC
delivery the runtime re-reads the channel's Hailo policy, connection and JOIN
state, and compares the captured channel generation. Disabling Hailo, removing
respond/chatter permission, leaving the channel, reconnecting, queue expiry or
shutdown revokes the pending reply. Diagnostics and Prometheus series contain
only bounded outcomes, never trigger text, drafts, edited replies or nicks.

## Delivery stages

- **MB720-A:** per-channel brain registry, legacy seed, explicit save boundary,
  reply-before-learn ordering and updater preservation.
- **MB720-B:** provider-neutral language-aware post-editor request and strict
  fallback validator.
- **MB720-C:** message normalization, nickname placeholders, independent
  learn/respond/chatter policy, cooldowns and the bounded queue are delivered
  in local Hailo turns.
- **MB720-D:** asynchronous runtime wiring, aggregate metrics, development
  pilot, late revocation, fallback delivery and documentation qualification.
- **MB720-E:** reloadable nickname exclusions and one ingress identity gate
  prevent configured bots and Mediabot's own RSS/news output from entering
  context, activity accounting, replies or channel-brain learning.
- **MB720-E-R1:** qualification keeps real provider editing as live integration
  evidence, while late revocation and fallback are exercised by the exact
  focused runtime contract instead of a timing-sensitive operator race.

The MB720 development gate is complete. A live edited reply established the
integration path without raw text in diagnostics. The exact focused runtime
contract then completed a provider after channel disable, required the late
`disabled` outcome, proved that no candidate was emitted, injected provider
failure and proved delivery of the original learned draft. This avoids both a
sabotaged live provider and an operator timing race.

Focused and fast validation covered the delivery stages, followed by the
single full suite attached to the accepted commit. Cross-instance rollout and
observation are tracked by MB722 in the 3.5 roadmap; they do not reopen the
completed MB720 engineering work unless a new defect is observed.
