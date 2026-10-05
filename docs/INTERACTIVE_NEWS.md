# Interactive news on the development line

MB815 covers `!news`, `!actualités`, `!actualites`, `!actualité` and `!actu`.
This is a 3.6dev improvement, not a new 3.5 release guarantee. Scheduled RSS
posting and its per-channel limits remain separate from these commands.

## Use

```
!news
!actualités
!news cadmium
!news transport en
!actualités énergie es
```

The normal shared language resolution applies: an explicit `fr`, `en`, `es`
or `lang=xx` token, then channel language, then the configured default. The
existing parent cooldown is shared by the aliases. News processing still uses
the isolated command worker, keeping network work off the IRC event loop.

There is no public waiting message. A successful bulletin opens with a compact
news paragraph covering concrete developments, followed by the corresponding
dated publisher links. Related stories may share a sentence without inventing
a causal connection. Neither the opening nor the links have list numbers.
Each link includes a short title hint of at most 64 UTF-8 bytes (roughly 55
characters), ending between words with an ellipsis when needed. Long headlines
are not repeated after the summary; a short title may fit in full. Long original URLs reduce the hint budget;
URLs are always preserved exactly or omitted if they cannot fit.

The opening targets 320 UTF-8 bytes in two or three short sentences, with a hard
600-byte limit. Word wrapping preserves the entire accepted paragraph in one
or two IRC lines. Up to three source references are packed in order onto as few
400-byte lines as possible, without clipping URLs. With ordinary shortened
links, a brief paragraph and all three references usually occupy two lines;
a longer accepted paragraph takes three. Long original links may need their
own lines. Every selected source must be represented once in the internal
summary evidence; source ids remain internal to the model contract.

The parent process delivers the first line immediately when idle, then spaces
news lines by at least 1.5 seconds through a single queue shared by the bot's
news requests, including requests from different channels. A late event-loop
callback sends one line and starts a fresh interval, without a catchup burst.
The existing AntiFlood helpers still apply and can defer output further; this
spacing concerns interactive news, not every message sent by the bot.
The queue holds at most 60 pending lines and expires delayed lines after two
minutes. Pending news and old worker completions are dropped on an IRC
connection change. Missing timers do not trigger an immediate flush.

One event covered by several publishers should not occupy several slots.
Editorial order comes from the localized Google News feed; the bot does not
claim an objective ranking of the world's most important events.

## Evidence and synthesis

1. Select specific dated press articles. The default feed uses a 36-hour age
   limit. A requested topic starts with one day and may widen to three/seven
   days when too few articles are available. Publication hours and timezones
   are preserved; generic daily roundups, missing dates and future dates are
   rejected rather than presented as current news.
   Calendar-only dates compare from midnight UTC, without inventing a publication
   hour. Today's date remains usable in the morning; tomorrow's is rejected.
   RSS regression fixtures use English RFC names independently of host locale.
2. If `tavily.API_KEY` is configured, look up the selected headline within its
   publisher's domain. Only a sufficiently matching title, publisher and usable
   excerpt may add detail. A supplied excerpt date must be consistent with the
   selected article. The visible link then becomes the matching article URL.
   If Google RSS fails, bounded Tavily discovery can supply dated alternatives.
   No Tavily key is required when the RSS feed is usable.
3. Ask the existing provider-neutral client to produce a structured opening summary with evidence ids for each section.
   Use the first configured provider in Anthropic, OpenAI, Gemini order, with
   its existing endpoint/model configuration. The request executes synchronously
   **inside the command worker**; there is no nested worker/callback, chat
   history, pinned context or personal conversation prompt.
4. Validate ids, article alignment, output shape, source attribution, numbers
   present in the supplied evidence, and IRC byte/control limits. URLs are
   constructed from articles by the bot, never invented by the language model.

Tavily provides excerpts, not a guarantee that the full article was read. A
headline-only summary must stay within the headline's facts and preserve
uncertainty. Lexical/number checks are useful defenses but do not prove every
sentence correct: the live acceptance check must assess the quality of wording
and verify any details against the linked article.

If enrichment fails, synthesis can still use the selected headlines. A
multi-source section may use the full paragraph budget, avoiding rejection of
a valid combined paragraph merely because it exceeds the single-source limit.
Other evidence, numeric, control and total-length checks still apply.

A rejected model answer gets at most one fresh correction request to the same
provider, using the same evidence and a fixed rejection code. The rejected text
is never replayed. Correction requires at least five seconds of synthesis budget
and leaves the existing seven-second reserve for links and output. A provider
outage is not retried. Logs distinguish missing configuration, provider failure,
JSON/shape, source coverage/alignment, unsupported numbers, length and time
budget issues; they contain no raw response, article text or credentials.

If synthesis remains unavailable, the opening honestly reads `D’après les
titres`, `From the headlines` or `Según los titulares`, followed by the retained
headlines as one unnumbered paragraph and the same packed source links. This is
an extractive fallback, not a claimed AI synthesis. Complete ordinary headlines
retain conditional wording and attribution, so the fallback may need more lines
than the generated summary. If no sufficiently fresh, specific sources remain,
the bot sends one availability reply. It does not substitute undated or old pages.

## Budgets and unchanged state

The command reserves time within its existing 45-second worker limit: RSS calls
have a three-second timeout, Tavily calls at most four seconds, synthesis at
most twelve seconds with its timeout reduced to the remaining budget, and URL
shortening at most two seconds per link. Enrichment stops early when needed.
Network response sizes and redirects are bounded. Very long original links
are omitted rather than emitted partially. The normal shortener destination
checks and exact-URL fallback remain active.

No configuration key, table, grant, feed subscription, channel setting or
business-data write is introduced. No conversation history is updated by this
stateless bulletin. No credentials or raw provider response are logged.

## Development acceptance before commit

Run the package preview, then the source application and focused, fast and full
Perl suites as separate steps. Apply does not restart a bot or commit anything.
The new isolated test exercises the real command and the real AI client through
bounded HTTP adapters; no paid API, live database or IRC session is needed.

After validation, restart only the intended development instance through the
existing operator procedure and wait for its channel rejoin. Try `!news`, wait
for the shared cooldown, then `!news cadmium` or another current topic. Check:

- no initial search announcement, no list numbers, and packed publisher/title hints;
- short explanations of the retained events, with attributed claims;
- paragraph facts, source dates and links referring to the same events;
- explicit extractive wording and fixed diagnostic codes when synthesis fails;
- no roundup/video landing pages, duplicated event slots or false extra figures;
- forced/channel language, topic relevance and acceptable response delay;
- at least 1.5 seconds between news lines, without catching up in a burst.

Review live wording before using the existing `commit.sh` workflow. Promotion
to production remains a separate update decision. A patch test pass does not
claim live API success or editorial quality.
