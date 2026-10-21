# MB873 — exact DansTonChat search links in result order

Base: `snap_mediabot_v3_teuk_20261021_104846.zip`, after MB872,
`3.6dev-20261021_084707`.

## Select a complete usable target

`parse_search_ids()` previously searched the entire HTML for a substring like
`/quote/123.html`. A foreign URL, nested redirect, script or comment could
therefore contribute a DTC quote number. Zero, leading-zero and overlong IDs
also reached the search header even though the canonical detail fetcher rejects
them. Such matches could prevent a later search source from being tried.

The parser now uses the HTML::TreeBuilder dependency already present in this
module. Only anchor `href` attributes can contribute results. HTML entities
are decoded by that parser. Targets must satisfy the existing complete DTC
quote URL selector and canonical ID builder, which admits positive numbers
of at most twelve digits without leading zeroes.

Supported targets are root-relative `/quote/ID.html` links and HTTP(S) links
to `danstonchat.com` or `www.danstonchat.com`, including protocol-relative
links. The existing query/fragment suffix support remains. A URL merely
containing a quote path in another path or query is not a quote target.

DuckDuckGo links use the supported root or `/l/` redirect shape, either
relative or on the main/www/lite/html DuckDuckGo host. Exactly one `uddg`
target is decoded once and checked against the same DTC identity contract.
Duplicate target parameters, foreign wrappers and nested foreign destinations
do not create search results. No redirect URL is fetched by this parser.

## Keep mixed results in order

The previous parser ran one scan for direct links and then another for encoded
DuckDuckGo targets. A lower direct hit could therefore precede the first
wrapped result. Since the command automatically displays the first ID, the
user could see a different quote from the first usable search result.

A single pass over anchors now retains document order across both forms.
Only usable, distinct IDs consume the existing twenty-result parser bound.
The source still returns at most five results. A page containing only noise
or invalid links now allows the existing narrow-search, lite-search and DTC
site-search plan to continue rather than falsely succeeding.

These are HTML document order guarantees, not a new relevance-ranking policy.
Only actual hyperlink targets are admitted; a number present solely in page
text, scripts, comments or non-href attributes is intentionally ignored.

## Preserved runtime contracts

- `!dtc` and `!bashfr` share their current command/worker path.
- The three-source search plan and per-attempt eight-second HTML timeout.
- The existing input-size and query bounds and deduplication/result limits.
- The canonical detail fetch and its final-URL/page identity checks.
- Random and direct-number modes, reply formatting, truncation/source links,
  requesting channel, chanset guards and worker lifecycle/delivery ownership.
- Existing shared HTTP DNS, transport and peer safeguards.

No new dependency is introduced. HTML::TreeBuilder was already used by the
detail parser in this module. Search parsing builds and deletes a bounded-input
HTML tree in the existing command worker instead of scanning raw HTML twice.
No schema, migration, private configuration, VERSION or service change occurs.

## Offline regression coverage

- `1290_mb873_dtc_search_link_identity.t`: complete target admission, host and
  path boundaries, numeric identity bounds, supported redirects, entities,
  non-link noise, mixed result order, deduplication and parser limits.
- `1291_mb873_dtc_search_delivery.t`: actual source fallbacks and five-result
  selection; both real public handlers through the native CommandAsync
  fork/pipe/replay; selected detail URL, matching quote output and unchanged
  refusal of a mismatched canonical detail page.

Only HTTP and final IRC/chanset/DB fixture boundaries are replaced. Real
search/detail parsing, formatting, handlers and worker transport execute.
The tests use local HTML, do not contact search engines or DTC and do not
claim to validate their current public markup or search ranking.

Executed results and local environment limitations are in the package's
`QUALIFICATION.md`.
