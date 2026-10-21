# MB880 — Reusable IRC modules, compatible runtime boundaries

Base: `snap_mediabot_v3_teuk_20261021_142719.zip`, after MB879,
`3.6dev-20261021_122241`. This round extracts existing behavior into five
modules alongside TextBudget. It does not introduce a new sending engine.

## Public entry points

| Module | Suggested imports | Contract |
| --- | --- | --- |
| `IRC::Target` | `is_channel` | Historical prefix classification for `#`, `&`, `!`, `+`; not full validation or permission checking. |
| `IRC::CaseMapping` | `fold_irc` | Existing lc-based folding, with `ascii`, `strict-rfc1459` or `rfc1459`. Default is RFC1459; unknown names take the historical ASCII-mode path. |
| `IRC::Text` | `decode_irc_text`, `sanitize_line`, `redact_service_secret` | Existing inbound decoding, shared CR/LF/NUL normalization and private service diagnostic masking. |
| `IRC::Presentation` | `format_reply` | Existing compact Markdown renderer, preserving its maximum two lines, 120–400-byte wrap range, styles and suffix policy. |
| `IRC::PacedOutput` | `queue_privmsg_chunks`, `queue_notices` | Existing PRIVMSG batch pacing and help NOTICE pacing, kept as separate policies. |

`IRC::TextBudget` keeps the MB879 byte-counting, wrapping and legacy truncation
contracts. `Text::sanitize_line` delegates to its existing normalizer rather
than introducing another implementation.

Example, inside an existing parent-side bot command:

```perl
use Mediabot::IRC::Presentation qw(format_reply);
use Mediabot::IRC::PacedOutput qw(queue_privmsg_chunks);

my $lines = format_reply($text, wrap_bytes => 400, max_lines => 2);
queue_privmsg_chunks($bot, $target, $lines, 750_000, 'command');
```

The queue's argument is a delay in microseconds, matching the old helper.
It returns the number of retained chunks, not a durable wire-delivery
acknowledgement. Use the established immediate sending/acknowledgement path
when a feature requires expiry-aware or durable delivery.

## Compatibility and adoption

Helpers keeps `isIrcChannelTarget`, `_is_irc_channel_target`, `decode_irc_text`,
`_redact_irc_service_secret_for_log` and `queueBotNotices`. The public exports
are unchanged. Context and RSS::Repository use the shared prefix classifier.

Case folding is reused by Fullop, AI::ConversationRuntimeState,
AI::ConversationExclusion, AI::ConversationRoom, AI::MetaPolicy,
Hailo::Normalizer, Radio::Public and XAuth. Each caller keeps its own input
validation and undef/reference policy. Fullop keeps its selected mapping;
the conversation runtime still starts in conservative ASCII mode until
ISUPPORT selects another supported mapping. This is not a migration of
identity keys or a new Unicode case-folding policy.

AI::IRCOutput remains the compatibility facade for `format_ai_reply`, with
its two exports, version, constants and private rendering symbols retained.
The original renderer lives in IRC::Presentation; its public generic entry
point is `format_reply`. The existing provider prompt instruction remains
in AI::IRCOutput. Provider selection, requests, caching and parsing are not
moved into the IRC layer.

Claude keeps `_queue_irc_chunks`, forwarding to PacedOutput. Both pacing
implementations keep their original bodies and state keys. NOTICE's existing
unqualified send is resolved by a forwarding function that calls Helpers at
delivery time. Every PRIVMSG and NOTICE continues through the same Helpers
facade, preserving worker output interception and ordinary sender policy.

PacedOutput has no bot/provider dependency at module load time. Helpers and
Countdown are loaded lazily when its public queue functions need them.
The other new modules are pure utilities and do not load the bot runtime.

## Policies deliberately kept separate

- PRIVMSG batches send their first chunk immediately, serialize subsequent
  batches per historical lc target key, and use the existing per-batch delay.
  Their queue key is not changed to RFC1459 folding in this round.
- Help NOTICE batches schedule their first line too, retain the shared timer
  list, 1.5-second spacing and 16-line cap. Timer setup failure keeps its
  immediate fallback. This is not the PRIVMSG scheduling algorithm.
- The no-loop and scheduled PRIVMSG paths retain their distinct existing
  exception behavior. No retry, expiry or catch-up policy is added.
- The actual `botPrivmsg`, `botAction`, `botNotice` and AntiFlood deferred-send
  implementations are unchanged. NoColors, badword cache/filtering, metrics,
  logs, history and contextual `no_defer` retain their current order.
- RSS pacing, Hailo reply queues, Spark/conversation expiry and worker replay
  keep their specialized state machines. They are not forced into the two
  extracted queues.
- No nickname/channel validation is replaced with folding or prefix
  classification. HTTP, DB/storage and Partyline rules remain outside this
  IRC utility refactor.

## Validation approach

New tests load each module in a fresh interpreter without Helpers or AI,
exercise three legacy/new loading orders, verify folding and routing modes,
encoding flags, invalid legacy bytes, secret masking, rendering aliases and
byte limits. A deterministic timer fixture drives the actual pacing code:
concurrent batches, independent targets, cleanup, failures, no-loop fallback,
NOTICE caps and scheduling fallback. The actual CommandAsync output facade
must collect generic sends without leaking to the real sending functions.

Seven historical source checks now read their implementation owners; their
runtime assertions remain. Separate source/candidate processes compare sampled
values, flags, wire bytes, warnings, errors, timer traces, output order,
metrics and logs. The full-suite and delivery results are recorded in
`QUALIFICATION.md` in the installer package, including local environment
limitations. Sampled equivalence and tests do not prove every possible input.

No SQL schema, migration, private configuration, VERSION, service or test
runner change is included. Nothing in the package commits or restarts a bot.
