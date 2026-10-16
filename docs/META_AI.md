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

### Open-domain requests, beyond news and topic lists (MB826)

In `WEB_MODE=auto`, addressed informational requests use general web research
by default. A request need not start with a question word or contain a topic
such as CVE/software, the word "recent", or an explicit search instruction.
Statements and fragments such as "Paris Lyon en train", "je voudrais comprendre
les marées" and "the author of this book" are eligible even if all contributors
return `needs_web=false`. Profiles such as CVE/software/documentation tune the
research; they do not define which subjects the bot can handle.

Acknowledgements, personal keyword/name recall, creative or user-text tasks,
and simple calculations/conversions do not force public research. Contributors
can still request verification when external facts are needed. This distinction
is heuristic: it does not promise perfect intent understanding or an answer to
every question. Search uses Tavily general search with native OpenAI fallback,
not a Google browser session. No routing provider call or editorial retry is
added; existing request budgets and IRC pacing remain in effect.

```text
mediabot: je voudrais comprendre pourquoi la mer monte et descend
mediabot: Paris Lyon en train
mediabot: la différence entre une liseuse et une tablette
mediabot: je cherche les règles officielles du go
mediabot: les horaires du musée aujourd’hui
mediabot: quel est le détail de CVE-2024-3094 ?
```

The CVE example is a lookup request, not a claim about current exploitation.
Requested CVE IDs are retained in both search queries; a contributor cannot
substitute another identifier. Short follow-ups can resolve the prior **user**
question. Source rows without any requested ID in their title, text or URL are
excluded. This guards identity, not factual entailment. Synthesis asks for the
affected product/versions, conditions/impact, and documented fixes or mitigation,
distinguishing CVSS metadata from evidence of active exploitation. Unknown
versions or exploitation status remain unknown.

Software answers should name one or two tools, their task/platform fit and a
material limitation. Free-of-charge, open source, trials and freemium restrictions
are distinct claims to verify from official project/licence documentation.
Essential missing platform/requirements should prompt clarification. No software
is downloaded, installed or executed by this consultation feature.

All Search calls explicitly use `topic=general`. Technical/reference/software
lookups use Tavily `include_domains_mode=prefer` on the first attempt so an
operator's preferred domains do not exclude other projects or vendor advisories.
General/current questions now use the same soft preference: no first search
is confined to institutional/news domains. A project, museum, tool, transport
operator or other relevant site can be returned immediately. No arbitrary 30-day lower bound applies to a CVE reference
or project licence page; explicit recent-news/publication-date requests retain their
date filters. Older or undated documentation can therefore remain useful.
All existing passage, citation, shorturl, byte and pacing checks still apply.

`WEB_MODE=auto` researches informational requests by default across subjects and
FR/EN wording. Contributors propose standalone search queries resolving actual
follow-up references; acknowledgements between a question and its follow-up are
skipped. Independent new questions keep their own subject. Neither speaker
labels nor earlier assistant claims become the fallback query.

Tavily Search first prefers `PREFERRED_DOMAINS`, then can broaden the search.
MB821 chooses contributor queries in configured order, independent of callback
arrival order. Short follow-up fallback queries retain the previous user subject,
excluding speaker labels and previous assistant claims. Subject-specific official
sites (e.g. ANSSI) are preferred only if already in the operator's domain list.
An independent new question does not inherit the previous user topic in its
fallback query. Genuine referential follow-ups retain that subject. If fewer
than two selected pages overlap the query, one broader attempt uses the next
contributor query. At most two searches and one extraction batch are made, with
up to three public HTTP(S) sources; this is not an open-ended research loop.

Explicit recent news/reports/examples use a rolling 30-day publication window;
today/this-week publication requests use the current UTC day/seven-day window.
A current fact (opening hours, timetable, rules, price or forecast) does not
require a page published in that window: older official reference pages remain
eligible. Current validity and publication recency are different questions.
An explicitly requested publication year gets that calendar interval. An incident year or "latest stable version"
does not imply that publication window. The API publication filter and local
date checks exclude stale/future dated results; ISO and documented RFC date
formats are normalized. Unknown dates remain unknown, not retrieval timestamps.
Ranking uses bounded query overlap, configured domains and publication dates;
this heuristic is not proof that a result is relevant or editorially independent.

Extraction includes the query and bounded page chunks; local passage selection
keeps matching sentences/paragraphs beyond navigation-heavy prefixes, within
40,000 inspected and 5,000 retained characters. Page extracts and search snippets
remain distinct untrusted evidence; publication, incident and retrieval dates
are not interchangeable. Missing dates and gaps must be stated in the synthesis.

The synthesis must select existing source IDs; invented IDs fail. URLs come
from retrieved source metadata, never model-generated text. If shared search
fails, an OpenAI Responses call must complete native `web_search` and return
citation metadata. If neither works, the bot reports that verification failed
instead of passing an unsourced current answer off as researched.

There is no browser session, arbitrary shell execution, tool loop or moderation
action in this feature. URL checks reject credentials, literal private IPs,
single-label/local hosts and non-web schemes. Page retrieval is delegated to
Tavily; the bot does not fetch arbitrary model-generated destinations itself.

## Retrieved proof passages and researched replies

MB824's IRC runtime selects proof passages by identifier instead of asking the
synthesis model to reproduce their text. After research and date checks, the
program builds a local catalogue from the actual retrieved source text:

- Up to three sources, 5,000 normalized characters per source, at most 40
  passages per source, each 12–240 characters. Small overlaps retain details
  at chunk boundaries; no passage spans the extractor's non-contiguous joins.
- Each `passage_id` is bound to its source identity, destination and content.
  Identical source content can produce identical IDs; resolution always uses
  only the current question's catalogue, never a global or historical lookup.
- The model returns `answer`, one or two `source_ids`, `basis`, and `support`
  entries containing `source_id` plus one supplied `passage_id` for each source.
  It returns no free-text proof. The local program resolves those IDs to exact
  retrieved text, verifies that source snapshots have not changed, then applies
  the unchanged literal `validate_support` check.

For compatible OpenAI Responses models, `meta_synthesis_passages` and
`meta_passage_repair` use strict structured outputs whose `passage_id` enum
contains only the actual catalogue IDs for that request. The provider-neutral
request validates that bounded ID list before payload creation. Claude/Gemini
select from the same catalogue in their prompt and face the same local checks;
neutral catalogue metadata does not become an unsupported API field.

Unknown IDs, a passage belonging to another source, invented top-level source
IDs or changed source snapshots are final failures. Missing/malformed selection
fields can receive one format correction with the same catalogue and actual
synthesis provider; contributors and research are not repeated. Normal valid
selections add no new request. Free-text quotes are never silently matched,
translated or replaced to rescue an invalid selection.

The accepted event is:

```text
META_AI evidence=passage_ids action=accepted
```

`unknown_passage` and `source_changed` events identify rejected catalogue
bindings. Exact passage existence and destination binding are mechanical
checks, **not proof that every answer claim follows from that passage**. The
model still judges relevance, completeness and semantic support; malicious or
poorly extracted page text remains untrusted. `partial` and `insufficient`
statuses preserve the existing limited-answer behavior. Shorturls, two answer
lines plus a source line, delivery pacing, private memory and command access
checks retain their existing behavior.

### Direct-engine quote compatibility

Direct callers constructing `MetaChat` without the runtime's `passage_ids`
mode retain the earlier quote contract below. There is no implicit fallback
from a failed catalogue selection to that contract. Native web search retains
its separate tool-citation assurance level.

In that compatibility mode a researched synthesis returns one or two `source_ids`
pointing to the evidence supplied for that question, a `basis` value
(`supported`, `partial` or `insufficient`) and one `support` entry per selected
ID containing that ID and a verbatim 12–240-character passage. Compatible OpenAI
Responses models use a strict `text.format` JSON schema for `meta_synthesis_web`
and `meta_citation_repair`. The runtime independently checks IDs against the
actual evidence and each passage's presence in the selected text, allowing only
whitespace/Unicode/typographic quote normalization. A quote that exists is an
evidence anchor, **not proof of logical entailment or factual correctness**.
Models still judge relevance, completeness, interpretation and evidence status.
Unverified contributor answers are excluded from researched synthesis; their
research directions and the conversation remain context rather than evidence.
The old May 2024 GPT-4o snapshot and fine-tuned model IDs retain the prompt-only
contract. Stable replies, native web searches and legacy commands keep their
existing formats. See the official [Structured Outputs guide](https://developers.openai.com/api/docs/guides/structured-outputs?api-mode=responses).

If a successful, parsed synthesis omits references/evidence fields, selects
more citations than the two-link presentation can show, or returns a malformed
or unmatched supporting passage, the bot withholds it and requests **one**
complete regeneration from that same provider using the original conversation
and the same source extracts. The new prompt requires rebuilding the claims
from exact contiguous source passages, without translating, paraphrasing or
inserting ellipses in quotes. The rejected answer is not sent back as evidence.
The identical validator must accept the new result; no quote is silently fixed,
no arbitrary links are attached, and contributors/search are not repeated.
Invented or malformed top-level source IDs are still rejected immediately.
A second bad passage, invalid evidence field, omission, provider failure,
empty answer or malformed synthesis remains a failed reply;
no uncited current answer enters IRC or conversation memory. `partial` puts a
qualification at the start; `insufficient` replaces the draft with a localized
statement that the requested detail is not established, while retaining the
checked source links. No new critique call is added to normal valid responses.

Native OpenAI web fallback still uses its completed-tool citation metadata;
it does not provide extract anchors to this local validator. It is instructed
to give concrete dated facts and limitations, and cannot exceed two sources.
Native citations and locally matched extract anchors are different assurance
levels. Live acceptance must cover both provider compatibility and answer quality.

`META_AI completed` and `META_AI failed` metadata are available at the normal
log level. Successful completions show contributor count, web use, degradation,
whether one citation correction was used, matched anchor count (`anchors=0` for
stable/native replies) and accepted shorturl count. Failure codes distinguish
`web_missing_citations`, `unsupported_web_answer`, `web_missing_evidence`,
`web_evidence_mismatch` and `web_synthesis_failed`.
Failure metadata retains contributor count and degradation even when the final
answer is rejected; `web_attempted=1` records research without falsely claiming
the rejected answer was verified. `citation_repair=1` records a correction attempt
even if it ultimately fails. The generic `web_evidence_mismatch` error covers
both malformed support and an unmatched quote; the evidence event distinguishes them.

Per-question events identify each configured contributor independently:

```text
META_AI provider=gemini outcome=api_failure status=503 error=http_error category=service_unavailable retries=1
META_AI evidence=mismatch action=retry
META_AI evidence=mismatch action=rejected
```

`outcome` distinguishes `usable`, `empty_draft` and `api_failure`. Provider,
outcome, error and category are closed allowlists; HTTP status and retry count
are bounded. Evidence reasons distinguish `missing`, `invalid`, `mismatch`,
`invalid_ids`, `missing_citations` and `too_many_citations`. A retry event is a
single additional synthesis request, not a new Gemini/provider retry policy.
View the metadata on nbot with:

```bash
sudo -n journalctl -u mediabot@nbot.service --since '10 minutes ago' --no-pager -o cat |
  rg 'META_AI (provider=|evidence=|completed|failed)'
```

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
| `GEMINI_FALLBACK_MODEL` | empty | Optional explicitly validated Gemini text model for the existing second transient attempt; never an extra third call. |
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
service-public.gouv.fr legifrance.gouv.fr cyber.gouv.fr cybermalveillance.gouv.fr
cve.org nvd.nist.gov cisa.gov cert.ssi.gouv.fr who.int reuters.com bbc.com
franceinfo.fr developers.openai.com platform.claude.com ai.google.dev`.

## Gemini acceptance and transient failures (MB822)

An HTTP::Tiny 599 alone is not a verdict about model access, billing or a retired
model. The checker prints the actual HTTP status plus a bounded category for
DNS, TLS, timeout, connection, unidentified transport, access, quota, model,
request, service overload, or exhausted visible-output budget. It prints no raw
provider error message, body, API key or network exception text.

To check Gemini even when the instance currently lists only OpenAI and Claude:

```bash
perl tools/meta_ai_check.pl --conf mediabot.conf --provider gemini
perl tools/meta_ai_check.pl --conf mediabot.conf --provider gemini --live
```

`--live` performs a small paid test. A meta/probe Gemini request can retry once
after a 0.75–1-second jittered delay for an overload/server failure or recognized connection/
timeout failure. If private `[meta_ai] GEMINI_FALLBACK_MODEL` names a different, validated Gemini
text model, the second attempt uses it. Empty means retry the same model. This
is a model change within Google, never a silent switch to another company.
Both attempts share the original request timeout; the first
gets half the available budget, the second gets only the remainder. Normal IRC
execution stays in the existing asynchronous provider worker, with the same
worker deadline. There is no retry on access, quota, bad model/request, DNS/TLS,
unidentified 599 or a successful response without visible text. Legacy standalone
Gemini purposes keep their single-attempt behavior. Overload can still persist.

An optional listing uses Google's fixed authenticated model endpoint, at most
100 advertised entries, and reports truncation. It excludes non-text model names
and does not prove that generation, quota or billing works for a listed model:

```bash
perl tools/meta_ai_check.pl --conf mediabot.conf --live --list-gemini-models
perl tools/meta_ai_check.pl --conf mediabot.conf --provider gemini --model MODEL_ID --live
```

The `--model` override applies only to that probe and disables fallback so
that success cannot conceal failure of the model being tested. The offline
check prints the configured fallback. A successful live check and runtime
provider metadata report the effective model, `model_fallback`, retry count and
original transient category. Logs omit prompts, answers, credentials and raw
error messages. A persistent HTTP 503 still means an upstream availability
failure; this change does not guarantee three successful contributors.

Meta JSON purposes request `application/json` from Gemini. Deprecated sampling
parameters are omitted for Gemini 3.6+ and newer generations; older model
temperature contracts remain unchanged.

The model override applies only to that probe. Known Gemini 2.5 models use their
supported `thinkingBudget` contract: LOW is 0 for Flash/Flash-Lite, 128 for Pro;
MEDIUM is 1024 and HIGH is 4096. Known 2.0 models omit thinking configuration;
other model IDs retain the `thinkingLevel` contract. No fallback model is chosen
silently. A successful probe does not enable Gemini: after live validation, add
it explicitly to private `[meta_ai] PROVIDERS` and, if needed, set `GEMINI_MODEL`.
Use the normal instance restart/update procedure and test actual concurrent
contribution. Source deployment never rewrites those private values.

API references: [Tavily Search](https://docs.tavily.com/documentation/api-reference/endpoint/search),
[Gemini API errors](https://ai.google.dev/gemini-api/docs/generate-content/api-errors),
[Gemini thinking](https://ai.google.dev/gemini-api/docs/generate-content/thinking),
[Gemini models](https://ai.google.dev/api/models).

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

Conversation-only replies use at most two IRC messages. Researched replies allow up to
two answer messages plus one compact sources message. Every payload remains
within 400 UTF-8 bytes, including link colour and underline controls. The
synthesis aims for at most 650 characters and concrete details rather than
introductory filler; it must distinguish confirmed status from speculation and
state when the evidence does not establish the requested detail. Those are model
instructions, not a guarantee of factual correctness; verify live answer quality.
Long answers are truncated; shared synthesis selects at most two supporting
sources so no selected third citation is silently hidden. Plain two-line answers
with a very short tail are reflowed at a sentence/word boundary without content
loss; styled replies retain the normal formatter.

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
Fallbacks can add attempts; an evidence correction can add one synthesis call. Question limits bound request volume, not a currency
budget; set spending limits in provider accounts too. One failed contributor
can leave a useful answer; the bounded contributor count and degraded flag are
logged without prompts, responses, hostmasks or keys. If all contributors fail,
there is no extra retry cascade. A failed conversation-only synthesis can use a surviving
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

## General-question acceptance (MB825)

Use varied subjects on an enabled channel, for example:

- `mediabot: où trouver les horaires du musée des Confluences ?`
- `mediabot: quel outil gratuit pour découper une vidéo sous Linux ?`
- `mediabot: what is the difference between an e-reader and a tablet?`
- `mediabot: à quoi sert Home Assistant ?`
- `mediabot: et sous Windows ?` after the software question.

Check that the answer addresses the actual task, sources support it, and
shorturls/pacing remain compact. A museum page need not be a recent article.
The goal is a sourced answer to general factual questions, not a guarantee
that every result is complete, that opening hours are current, or that an
accepted passage proves every generated claim. Validate those qualities live.
Command help and protected channel state still use MB820 local authorization;
web research never executes bot commands or grants rights.

Gemini references: [troubleshooting and retry policy](https://ai.google.dev/gemini-api/docs/troubleshooting),
[advertised models](https://ai.google.dev/api/models). Configure a fallback only
after its explicit live probe succeeds. Source deployment changes no private
provider model, key, channel allowlist or enabled flag.

## Useful compact answers (MB826)

The researched synthesis and native web fallback share one editorial contract.
They must address the requested parts and essential constraints, lead with the
answer, and use available room for a concrete supported detail, condition or
limitation. Comparisons explain the distinction and deciding criterion; how-to
answers give an action and its prerequisite; recommendations explain why an
option fits and the relevant trade-off. Definitions explain what something is
and what it is used for. A simple request can still get a short answer.

The contract discourages generic endings such as "available on the official
website" when the source line already supplies that destination. It preserves
that information when finding the official destination is the actual request.
It asks models to distinguish core/optional features, local/cloud-dependent
capabilities and free/paid extras when relevant, and to cover all parts rather
than spending the whole reply on an introduction. No local text-replacement
filter deletes legitimate factual sentences to enforce style.

These are model instructions, not proof that every generated statement is
correct. Fixture-backed tests verify actual provider payloads, real worker IPC,
proof resolution, Unicode qualifiers and unchanged delivery budgets; real prose
quality still needs live acceptance. Existing partial/insufficient evidence
handling, unknown-ID rejection and MB820 private authorization remain intact.

Acceptance should include varied subjects and informal requests, for example:

- `mediabot: je voudrais comprendre les marées, avec un exemple concret`
- `mediabot: la différence entre une liseuse et une tablette pour lire dehors`
- `mediabot: les horaires du musée des Confluences aujourd’hui`
- `mediabot: comment préparer un risotto sans vin ?`
- `mediabot: une randonnée accessible en Bretagne avec des enfants`

Judge relevance, coverage, practical detail, conditions, source quality and
compactness. Do not judge success only by the presence of links. An ambiguous
request should get a concise useful clarification, not invented context. A
source can be old and still be relevant; recency must not be fabricated.
