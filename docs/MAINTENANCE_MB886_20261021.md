# MB886 — Apple Music ownership and badge

Date: 2026-10-21. Base: the MB885 state validated on teuk.org.

## Visible change

Display `[AppleMusic]` instead of `[⌘Music]`. Keep the label white on grey
(`00,14`), the brackets white on black (`00,01`), all existing IRC resets and
the space before the displayed title. Rich details, artist deduplication and
the 300-byte legacy display truncation remain unchanged.

The old Unicode command symbol upgraded the composed message to character
text. Explicitly retain that representation with the new ASCII label so this
display request does not indirectly change encoding of legacy byte values.

## Module boundary

Move these seven implementations from `External::URL` into
`Mediabot::External::AppleMusic`:

- `_am_duration_from_iso` and `_am_duration_from_ms`;
- `_applemusic_url_info` and `_applemusic_extract_details`;
- `_applemusic_lookup_track` and `_applemusic_fetch_sync`;
- `_handle_applemusic`.

`External` imports the handler directly from its implementation owner. `URL`
imports aliases for all seven historical fully qualified names, retaining its
original optional handler export. The facade's 33 default exports and URL's
17 optional exports are unchanged. The 28 remaining named URL function bodies
are unchanged, including URL routing and the AppleMusic chanset gate.

The new module resolves the three shared URL HTML/UTF-8/browser utilities at
call time, preserving existing dynamic overrides and avoiding eager circular
imports. It can be loaded independently without loading URL or AI providers;
normal command execution still uses the facade's shared HTTP factory and
Helpers output boundary.

Apart from the badge label and explicit preservation of its old character
representation, the seven moved function bodies are unchanged. Keep the
structured iTunes lookup, HTTP then Chromium fallback, storefront handling,
cache keys and 600-second TTL, pending requests, worker parameters, completion
guards, error behavior, logger messages and output callback.

No SQL schema, migration, private configuration, VERSION, process service,
timer, generic URL policy or other external feature is changed.

## Validation and test size

Extend the existing `855_mb672_applemusic_lookup_async.t` from 21 to 30
assertions: canonical aliases, independent import orders, actual badge color
and reset bytes, character representation, cached output and dynamic browser
fallback. Retarget the existing badge/source checks in cases 200 and 702.
Add no numbered case file; all 1,156 existing cases remain selected by default.
The existing generic module-structure case automatically checks the new module.

The local qualification compares 46 original/candidate scenarios, normalizing
only the requested badge label. It compares bytes and UTF-8 flags, duration
and URL helpers, metadata, HTTP/browser call traces, returned values, cache
payloads, pending state, worker options, repeated completions, setup failure,
timeout and malformed worker results. Removing the representation-preservation
line is detected by four scenarios. This sampled comparison does not claim
equivalence for every possible input.

The package report records targeted and full-suite results, local environment
limitations, and a real application/reapplication/rollback rehearsal. Server
installation requires a completely passing unfiltered suite, security audit
and startup integrity check; no local failure is waived by the installer.
