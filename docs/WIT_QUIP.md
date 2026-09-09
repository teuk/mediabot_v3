# Wit and Quip

`+Wit` adds light, friendly wit. `+Quip` offers a drier, more pointed observation
when the exchange gives it a good opening. It can deflate a boast, notice a
contradiction or pick up a shared absurdity. It is prompted to stay quiet during
serious arguments, requests for help or personal distress, and to avoid piling
onto a person. These are model instructions; live tone still needs evaluation.

## One conversation budget

| Channel flags | Behavior |
| --- | --- |
| Neither | No Wit/Quip observation request or reply |
| `+Wit` | Existing gentle Wit request |
| `+Quip` | Contextual sharp wit, or silence |
| `+Wit +Quip` | One request chooses gentle wit, a sharper quip, or silence |

The two modes share the same process-lifetime channel state: one inflight
request, a minimum 90-second request interval and a minimum 120-second delivery
interval. An unsuccessful Quip request also spends its request interval. Adding
or removing a mode does not reset those budgets. No second mode is tried after
`NO_REPLY`. These are maximum opportunities, not a periodic speaking schedule.

The existing burst guard still suppresses 20 lines in 10 seconds for 180 seconds.
A Wit/Quip message rejected by output antiflood is discarded; it is never queued
to appear minutes later. Other bot output keeps its existing queue behavior.
Replies exceeding 400 UTF-8 bytes are also discarded, so accented text or emoji
cannot turn one conversational response into several IRC messages.

## Reading the room

Quip and the combined mode require at least three recent human lines from two
people. A dedicated bounded observer keeps at most eight lines of 240 characters
within five minutes. It drops commands, bot triggers and known bot text. Configure
`main.BOT_NICKS` accurately: unknown automation cannot be identified reliably.

Commands and known bot output leave a 30-second breathing space. Active local
games, active Spark events and pending Spark AI work also block a Quip request
and are checked again before delivery. Spark already sees the shared Wit/Quip
inflight signal. This does not merge every unrelated bot feature into one budget.

Both modes use the same conversation sender. Quip always requests provider
`auto`; the configured Anthropic, OpenAI and Gemini providers and their existing
fallback logic are selected by `Mediabot::AI::Client`. No provider-specific key,
model or HTTP implementation is added. No configured/working provider means
silence, never a locally generated imitation quip.

Speaker labels such as `speaker1` are assigned per request. Channel and identity
metadata are not attached; user-written text may itself mention people or places.
The AI receives recent text, the current line and, if recent, the bot's last
delivered conversational reply. All are untrusted data, not system instructions.
This context stays in memory and is not added to a database or persistent profile.

Any new human line invalidates a pending Quip/mixed reply. The final gate also
rejects an expired context, a response older than 30 seconds, a mode revocation,
disconnect/rejoin or master-switch disarm. Enabling both flags is not authority
to deliver a sharper response after `-Quip`, even if Wit remains enabled.

## Enable on one reviewed channel

1. Install the source and register the new chanset with
   `install/migrations/20260909_quip_chanset.sql`. This data-only migration is
   idempotent by name and enables no channel. Never hardcode its database ID.
2. Keep the instance's existing provider credentials in its private configuration.
3. The existing `main.WIT_SEND_ARMED=1` master switch authorizes delivery for
   **both** Wit and Quip. Missing or invalid values keep delivery disabled.
   Apply a configuration change through the normal rehash/restart workflow.
4. As an authorized operator, enable `+Quip` with the normal chanset command on
   the one intended channel. Keep `+Wit` for a combined tone, or remove it to
   evaluate Quip alone. Do not enable channels through a bulk SQL update.

When the master switch is off, opted-in channels can still exercise the existing
AI dry-run path and incur provider calls, but cannot emit. Disable both chansets
to stop that channel's Wit/Quip requests. Removing a flag through the bot uses
its normal cache invalidation; direct SQL edits can remain cached briefly.

## Observe before a wider rollout

Use the instance's application log, normally `mediabot.log`:

- `[QUIP_OBSERVE]`: `style=quip|mixed`, eligibility or a reason for silence.
- `[QUIP_AI]`: reply/no-reply and safe provider metadata; `room_changed` drops a stale reply.
- `[QUIP_SEND]`: final delivered/blocked decision.

Wit retains its existing diagnostic prefixes. These diagnostic records never
include the prompt, player nick or generated text. Ordinary existing IRC output
logging is unchanged.

Check Quip alone and combined with Wit using the same recent conversation:
one provider submission and at most one response, no private-message activation,
no bot loops, no follow-up after silence, and late revocation of a queued AI
result. Also observe an ordinary quiet conversation and a serious discussion:
a short, well-timed line or silence should feel more natural than a running
commentary. Offline tests prove routing and budgets; they cannot certify humor.
