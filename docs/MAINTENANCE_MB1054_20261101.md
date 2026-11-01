# MB1054 — Preserve URL identity at message boundaries

The shared URL extractor used whitespace as its only token boundary. A pasted
`<https://example.org/path>` therefore retained the closing angle bracket, while
copied `href="...">text` could retain surrounding markup. Terminal IRC styling
also remained attached to a bare URL. Those strings could miss provider identity
checks or reach a preview request with the wrong path/query.

Raw `<`, `>` and double quotes now delimit the HTTP(S) token. Percent-encoded
forms are unchanged. The existing punctuation and balanced parenthesis/bracket
logic now peels terminal layers together with IRC reset, bold, italic, underline,
reverse, monospace, strikethrough and numeric/hexadecimal color suffixes. Each
pass only shortens the token and stops when unchanged, so nested punctuation
and styling cannot leave one another exposed after a single cleanup pass.

Only terminal styling is removed. Internal controls are retained for downstream
validation, not joined into a new destination. Unicode/raw UTF-8 input and all
percent-encoded bytes retain their existing representation. This remains a
message extractor, not a new URL validator, HTML parser, redirect policy or
SSRF boundary. Existing provider opt-ins, cache admission, private-literal guard,
handlers and request policy remain responsible for their own boundaries.
No provider implementation, including displayYoutubeDetails, is changed.

## Validation

`1427_mb1054_url_message_boundaries.t` runs the shared extractor and historical
External facade, then the actual displayUrlTitle routing path. Only provider
delivery sinks, policy observations/cache admission and logging are local
doubles; the MixCloud identity parser and YouTube URL recognizer are real.
No HTTP request, API account, IRC server, live database or service is used.

Thirty assertions cover angle/href/quote boundaries, adjacent links, terminal
styling/colors, nested wrappers, Wikipedia parentheses, IPv6/query brackets,
encoded delimiters, Unicode/raw UTF-8, internal-control preservation, first-URL
selection, no input, generic/MixCloud show/profile/YouTube routing, disabled
provider gates, the existing private-host guard and warning-free execution.
Nineteen fail on the unchanged public runtime; eleven pass. All thirty pass
after the correction. The historical generic-title test retains its first-URL
assertion as a native execution check instead of requiring the old regex text.
Every other historical check remains unchanged; nothing is skipped or removed.

The delivery qualification records targeted/full results, baseline failures and
a public patch apply/test/reverse round trip.

## Operator flow

The package applies idempotently and requires the visible full `--progress`
suite, security/startup audits, generated command inventory and whitespace
checks. Only after success does it restart `mediabot@dev.service`, require a new
positive PID stable for ten seconds and invoke installed interactive
`commit.sh --skip-preflight` for commit/push and native 3.8dev VERSION progression.
The patch does not edit VERSION or the project README. No production deployment,
schema, configuration or dependency change is included. The private commit
helper remains installed locally and is not shipped.
