# Collective AI conversations and web research (MB818)

`mediabot: <question>` can ask OpenAI, Claude and Gemini concurrently, then
produce one concise reply. Each contributor receives the same conversation;
a synthesis compares their drafts. Agreement is not treated as evidence.
The feature starts **disabled**, and requires both an explicit pilot-channel
allowlist and that channel's existing `+chatGPT` setting.

## Natural questions about Mediabot (MB820)

Within an enabled pilot channel, addressed FR/EN questions can read the bot's
own knowledge without asking a provider to invent an answer:

```text
mediabot: quelle est la syntaxe de la commande addcmd ?
mediabot: how do I use rss?
mediabot: est-ce que le chanset +Hailo est positionné sur ce channel ?
mediabot: is +Spark enabled on #i/o?
mediabot: quand fais-tu des appels à Claude ?
mediabot: quel est ton modèle chez OpenAI ?
```

| Question | Source | Visibility and access |
| --- | --- | --- |
| Syntax of one public built-in | Actual running `CommandRegistry` help metadata | Public, like `!help`; describing a privileged command does not grant execution rights |
| State of one chanset | Bound read-only `CHANNEL` / `CHANSET_LIST` / `CHANNEL_SET` lookup | Caller-only NOTICE; bot login plus current Administrator+ or channel level ≥450 |
| Collective models | Safe configured provider/model labels | Public; no keys, endpoints, private configuration or account data |
| Training cutoff | No verified cutoff exists in configuration | Explicitly unverified; web retrieval is distinguished from model training |

Authentication uses the normal observed IRC hostmask resolver with its identity
cache bypassed, then fresh database role/auth/channel-access reads. IRC operator
status, nickname, a claimed role in a question or an old cached user do not grant
access. Deleted accounts, logout, unknown roles, database failures and insufficient
rights fail closed. Cross-channel reads require the same authorization on the
explicit target and remain private. Access is checked again before each delayed
private line; a revoked right cancels the remaining output.

Local replies have the same channel/instance per-minute limits, generation and
activation gates, 400-byte payload cap and 1.5-second pacing as collective replies.
They incur no provider request or paid daily budget, and do not enter the shared
conversation memory. Protected data never enters provider prompts, shared
history or completion metadata. A second participant cannot obtain a previous
private answer through a follow-up. Ask each state question explicitly.

This is a bounded consultation surface: one named built-in or chanset per question.
Ambiguous/unknown requests ask for clarification. Plugin/custom-command templates,
user/account listings, secrets, arbitrary configuration keys and command execution
are outside it. Natural mutation requests only explain the normal `!chanset`
command; they never change a flag. Standard commands retain their own permission
checks. The help catalogue's level label is explanatory metadata, not an access
decision; some commands also enforce ownership, subcommand or channel rights.

Normal provider requests also receive safe runtime facts so they do not mistake
Mediabot for a single model. Successful contributors for a turn are distinguished
from configured ones; an outage or synthesis fallback remains possible. Future
periods are not treated as already observed, dated sources after the current UTC
day are excluded, and numeric reference markers are removed from answer prose
while the validated sources line remains. These instructions and date checks
reduce misleading answers; they do not prove that every source supports every
sentence. Live acceptance remains necessary.

## Conversation and identity

Only questions explicitly addressed to the bot and successfully delivered
answers enter this memory. General channel chatter, private messages, Wit and
Hailo training do not enter it. Participants share channel context while keeping
separate speaker labels and public nicknames. Identity keys hash the observed
IRC nick/ident/host; raw hostmasks are not retained or sent to providers.
An observed NICK event preserves the speaker label. A reused nick with another
host is a distinct speaker. Reconnecting under an unobserved new identity does
not automatically link it to an older participant.

History is isolated by configuration path, network and channel. A private JSON
file survives restart. By default it keeps the last 12 completed exchanges and
expires a room after 24 hours of inactivity. Expired rooms are excluded and
removed on the next write; this is not a background deletion scheduler.
`mediabot: /forget` removes the requester's turns from this channel, invalidates
in-flight responses and still works after the mode is disabled. It does not
remove other participants' turns, IRC logs, backups or provider-side records.
Only compact text actually accepted by the IRC sender is retained. Partially
sent or rejected replies do not become completed exchanges.

The bot sends the selected history to each configured AI provider. OpenAI
Responses requests set `store=false`; provider account retention policies still
apply. Keep pilot-channel participants informed about this shared context.

## Research

`WEB_MODE=auto` starts research for current wording or when a contributor asks
for external verification. Contributors propose a standalone search query,
resolving follow-up references from the history. Stable questions can avoid a
web call. Detection is heuristic; verify it during live acceptance.

Tavily Search first prefers `PREFERRED_DOMAINS`, then can broaden the search.
At most two searches and one extraction batch are made, with up to three public
HTTP(S) sources. Page extracts and search snippets remain distinct evidence.
Publication dates are retained when supplied, never fabricated from retrieval
time. Source excerpts are bounded and treated as untrusted data.

The synthesis must select existing source IDs; invented IDs fail. URLs come
from retrieved source metadata, never model-generated text. If shared search
fails, an OpenAI Responses call must complete native `web_search` and return
citation metadata. If neither works, the bot reports that verification failed
instead of passing an unsourced current answer off as researched.

There is no browser session, arbitrary shell execution, tool loop or moderation
action in this feature. URL checks reject credentials, literal private IPs,
single-label/local hosts and non-web schemes. Page retrieval is delegated to
Tavily; the bot does not fetch arbitrary model-generated destinations itself.

## Researched reply format and missing citations

A researched synthesis must return a JSON answer with a nonempty `source_ids`
array pointing to the evidence supplied for that question. Compatible OpenAI
Responses models use a strict `text.format` JSON schema for `meta_synthesis_web`
and `meta_citation_repair`. The runtime independently checks IDs against the
actual evidence; the schema alone is not a factual verification mechanism.
The old May 2024 GPT-4o snapshot and fine-tuned model IDs retain the prompt-only
contract. Stable replies, native web searches and legacy commands keep their
existing formats. See the official [Structured Outputs guide](https://developers.openai.com/api/docs/guides/structured-outputs?api-mode=responses).

If a successful, parsed synthesis omits references, the bot requests **one**
format correction from that same provider using the original conversation,
drafts and source extracts. It never attaches arbitrary fetched links to an
uncited answer and does not repeat contributors or Tavily research. Invented
IDs and malformed citation fields are rejected immediately. A second omission,
provider failure, empty answer or malformed synthesis remains a failed reply;
no uncited current answer enters IRC or conversation memory.

`META_AI completed` and `META_AI failed` metadata are available at the normal
log level. Successful completions show contributor count, web use, degradation,
whether one citation correction was used, and accepted shorturl count. Failure codes distinguish
`web_missing_citations`, `unsupported_web_answer` and `web_synthesis_failed`.
No prompt, answer, source content, nickname, hostmask or API key is logged.

## Configuration reference

Add one `[meta_ai]` section to the **development** configuration. Existing API
keys remain in `[openai]`, `[anthropic]`, `[gemini]` and optionally `[tavily]`.
The source package never rewrites a private configuration.

| Key | Default | Accepted values and effect |
| --- | --- | --- |
| `ENABLED` | `0` | `0` or `1`; activate the collective addressed route. |
| `CHANNELS` | empty | Space/comma-separated channel names, e.g. `#mbtest #i/o`; exact IRC case-folded match. Empty enables no channel. |
| `PROVIDERS` | `openai anthropic gemini` | Names or registry aliases (`claude`, `gpt`, etc.); deduplicated. Unknown names are ignored. |
| `MIN_PROVIDERS` | `2` | `1..3`; minimum configured contributor keys, not a guarantee all calls succeed. Keep `2` or `3` for collective operation. |
| `OPENAI_MODEL` | `gpt-6.1-sol` | OpenAI contributor/synthesis model. The new route uses `/v1/responses`, low reasoning for GPT-5/6 and no unsupported sampling fields. |
| `CLAUDE_MODEL` | `claude-sonnet-5-5` | Claude contributor/synthesis model; low effort for Claude 5, `between_tools` for Sonnet 5.5. Earlier adapters keep their sampling contract. |
| `GEMINI_MODEL` | `gemini-3.8-flash` | Gemini contributor/synthesis model; LOW thinking for supported models. |
| `SYNTHESIZER` | `openai` | Preferred synthesis provider; existing automatic provider fallback remains available. |
| `TIMEOUT` | `25` | `5..45` seconds per HTTP attempt; existing worker deadline adds three seconds. |
| `MAX_TOKENS` | `2048` | `512..8192` output-token budget per AI request, including reasoning where applicable. |
| `MAX_JOBS` | `2` | `1..4` concurrent channel jobs per instance; one job per channel. |
| `RATE_MAX` | `4` | `1..12` accepted questions per channel per rolling minute. |
| `GLOBAL_RATE_MAX` | `8` | `1..30` accepted questions per instance per rolling minute. |
| `DAILY_LIMIT` | `100` | `1..1000` question reservations per UTC day, persisted in the memory file. Failed work consumes its reservation. A custom shared state file shares this budget. |
| `MEMORY_TURNS` | `12` | `2..24` completed question/answer pairs per room. |
| `MEMORY_TTL` | `86400` | `300..604800` seconds of room inactivity before expiry. |
| `STATE_FILE` | empty | Empty derives `cache/meta-ai-<config-path-hash>.json` next to the configuration. A relative custom path is relative to that configuration's directory. |
| `WEB_MODE` | `auto` | `auto`, `always`, `off`. `off` refuses questions identified as needing verification. |
| `PREFERRED_DOMAINS` | see below | Up to 32 space/comma-separated public domains, passed as Tavily preferences; search can broaden. |
| `SLEEP_US` | `1500000` | `1000000..5000000` microseconds between reply lines. |

Malformed/out-of-range integers fall back to the documented default. An invalid
web mode becomes `auto`. Memory files and locks use mode `0600`, newly created
parent directories use `0700`; symlinks and corrupt/oversized state are refused.
The file is limited to 4 MiB, 128 rooms and 256 actors per room. Access uses a
nonblocking lock, so another writer cannot stall the IRC event loop.

Default preferred domains: `nist.gov cern.ch nasa.gov esa.int insee.fr
service-public.gouv.fr legifrance.gouv.fr who.int reuters.com bbc.com
franceinfo.fr developers.openai.com platform.claude.com ai.google.dev`.

## Operator sequence

1. Preview and apply the reviewed source package; run focused, fast and full
   tests. No private config, running process, database, Git index or VERSION is
   changed by the package.
2. With the bot still unchanged, check the private dev configuration:
   `perl tools/meta_ai_check.pl --conf mediabot.conf`.
   It prints configured/missing keys and model identifiers, never credentials.
3. Add the `[meta_ai]` section with `ENABLED=0`, set only the desired pilot
   channel(s), and keep at least two contributor credentials configured.
   Optionally run `perl tools/meta_ai_check.pl --conf mediabot.conf --live`:
   this explicitly makes one small **paid** request per configured contributor,
   without IRC output, memory writes or web research.
4. Activate `ENABLED=1`, confirm the channel's existing `+chatGPT` setting using
   the normal chanset command, then restart only the dev service. Syntax-check
   and status/journal acceptance precede public tests.
5. Test stable facts, follow-ups from another nick, nick changes, recent facts
   with official links, failure behavior, restart persistence and `/forget`.
   Commit through the existing `commit.sh` workflow only after acceptance.

The checker validates file permissions and model access. It does not validate
chansets, live IRC generation, native web entitlement, Tavily billing or the
quality of answers. Those remain live acceptance checks.

Existing `!tellme`, `!ai`, `!claude`, `!gemini`, Wit and Hailo keep their routes.
When the new mode is disabled/unlisted, the addressed route keeps its previous
OpenAI behavior (except `/forget`, which remains a local erasure request).
The old `[openai] MODEL` and endpoint are not silently migrated by enabling a
new `[meta_ai]` model: standalone legacy commands need their own checked model
and endpoint configuration if that account requires migration.

## Delivery, cost and failures

Stable replies use at most two IRC messages. Researched replies allow up to
two answer messages plus one compact sources message. Every payload remains
within 400 UTF-8 bytes, including link colour and underline controls. The
synthesis aims for at most 650 characters and concrete details rather than
introductory filler; it must distinguish confirmed status from speculation and
state when the evidence does not establish the requested detail. Those are model
instructions, not a guarantee of factual correctness; verify live answer quality.
Long answers are truncated; not every retrieved source can be displayed.

The sources message uses up to two evidence URLs actually selected by synthesis.
An isolated presentation worker reuses the configured `[shorturl]` service,
shared cache, exact destination binding and failure circuit, with at most two
shortening attempts and a seven-second worker deadline. These are presentation
requests, not additional AI or search calls. Meta AI opts out of the historical
TinyURL fallback; existing RSS/news callers retain that compatibility. Missing
or failed private-service shortening preserves exact original-source URLs when
they fit the normal byte budget. A source line that cannot fit remains a failure
rather than an uncited answer. Configure the existing teuk.org service using
`shorturl.API_URL`, `shorturl.PUBLIC_BASE_URL` and its private credential; keys
stay in the instance configuration and never enter model requests or logs.

Accepted private-service aliases use light blue (IRC colour 12), underline and
a reset after each link. Separators and answer text retain their normal style.
Accidental literal line-break/bullet escape artifacts are flattened in provider
prose before output and memory retention; incoming prompts and evidence are not
rewritten. Quoted escape notation and ambiguous code/path sequences remain intact.
`meta_ai_check.pl` reports private-service readiness without exposing its key.
Lines are 1.5 seconds apart by default. The sender's flood rejection cancels the
reply instead of deferring it outside the generation checks. Generation,
activation and memory tickets are revalidated before each line.

Three contributors plus a normal synthesis mean four paid AI requests per
question, with search/extraction or a native web call for researched questions.
Fallbacks can add attempts; a missing-citation correction can add one synthesis call. Question limits bound request volume, not a currency
budget; set spending limits in provider accounts too. One failed contributor
can leave a useful answer; the bounded contributor count and degraded flag are
logged without prompts, responses, hostmasks or keys. If all contributors fail,
there is no extra retry cascade. A failed stable synthesis can use a surviving
draft and is marked degraded. Research failures are explicit.

Adding a fourth provider requires the shared registry, its adapter/client plan
and tests. It does not require changing the IRC syntax or memory protocol;
adding an unknown configuration name alone does not create an integration.

## OpenAI deadline and references

The official deprecation table includes legacy-model removals on **23 October
2026**. It does not establish a general API-key expiry on 22 October. Inspect the
actual account/model and test access before that date; rotate a key when the
account or operator policy requires it. Do not paste secrets into IRC or Git.
The public sample's legacy `gpt-4o-mini` default is not proof of the active
instance's model, nor of its retirement in that particular table.

- [OpenAI models](https://developers.openai.com/api/docs/models)
- [OpenAI deprecations](https://developers.openai.com/api/docs/deprecations)
- [Responses migration](https://developers.openai.com/api/docs/guides/migrate-to-responses)
- [OpenAI web search](https://developers.openai.com/api/docs/guides/tools-web-search)
- [Claude Sonnet 5.5 migration](https://platform.claude.com/docs/en/models/sonnet-5-5/whats-new-sonnet-5-5)
- [Gemini models](https://ai.google.dev/gemini-api/docs/models)
- [Tavily Search](https://docs.tavily.com/documentation/api-reference/endpoint/search)
- [Tavily Extract](https://docs.tavily.com/documentation/api-reference/endpoint/extract)
