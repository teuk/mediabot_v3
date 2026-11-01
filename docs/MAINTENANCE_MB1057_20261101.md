# MB1057 — Exact DCC numeric boundaries before network admission

Date: 2026-11-01 (Europe/Paris)

## Defect

The DCC IPv4 converter and active-port validator used Unicode-aware digit
matching with a permissive final anchor before numeric operations. An IPv4
field containing `134744072` followed by a Unicode digit or a trailing newline
could be accepted as the numeric prefix, yielding `8.8.8.8`. Unicode decimal
zero glyphs could also be coerced to zero when detecting passive mode, with
warnings and a request-mode change rather than refusal.

## Implementation

Keep exact unsigned-decimal reading inside DCC with a private `_ascii_uint`
helper. Require scalar ASCII digits and a strict end of input. Remove leading
zeros locally, compare the decimal spelling against the bound before numeric
conversion, then return a bounded value. IPv4 remains unsigned 32-bit; active
ports remain 1024 through 65535 inclusive. Even long leading-zero fields keep
their existing value without overflow or modification of the caller's scalar.

Both structural parsing and the native request handler now recognize passive
zero with an exact ASCII-zero match, without numeric coercion. The parser
still returns original numeric fields and its existing request types; it is
not an endpoint authorization layer. Structurally recognized Unicode-digit
fields stay active and the target validator rejects them before account lookup
or network delegation. This avoids changing malformed offers into bare CHAT
invitations or moving their payload to another parser/logging path.

The active handler and native partyline connection sink retain independent
target validation. Refusal logs show only bounded ASCII decimal port spellings
or fixed placeholders, preventing multiline, reference or huge raw-field dumps.
Canonical IPv4 output, service argument forwarding, passive tokens/redaction,
bare CHAT compatibility, account-level restrictions and blocked address classes
are preserved. No socket is opened by parsing or validation.

This patch does not redefine CTCP framing, opaque-token policy, reserved IP
policy, session authentication, invitations or network timeout behavior.

## Native evidence

Case `1430_mb1057_dcc_numeric_boundaries.t` uses the real DCC module,
Mediabot request handler and partyline active connection method. Only account
lookup, logging, passive delegation and the final loop connect operation have
local sinks. Unexpected database operations throw; no listener or actual
network connection is opened.

Thirty assertions cover Unicode digits, mixed numeric prefixes, CR/LF suffixes,
signs, decimal/exponent spellings, references, undef and overflow; leading zeros,
IPv4 bounds and inclusive port limits; Unicode versus ASCII passive zeros;
raw CTCP offers, ordinary private commands and bare CHAT; refusal before lookup
and connect; independent sink validation; bounded diagnostics; valid native
active/passive delegation; token preservation/redaction, existing token alphabet,
privilege restrictions and warning-free operation. Twelve fail on the untouched
runtime; all pass after correction. Historical DCC/partyline tests are unchanged.

## Delivery

Scope: DCC, Mediabot core, partyline Transport, CHANGELOG, this note and one new
native test. The operator script requires the visible full `--progress` suite,
security/startup audits, generated command inventory and whitespace checks
before restarting `mediabot@dev.service`. It then requires a new positive PID
stable for ten seconds before the installed interactive `commit.sh
--skip-preflight` handles commit/push and the next native 3.8dev VERSION.
Do not edit VERSION manually. PID stability alone does not prove IRC reconnect.

No project README, schema, configuration, dependency, production, radio or
YouTube implementation change. No private commit helper is distributed. Local
qualification results and environment limits are in the package's QUALIFICATION.md.
