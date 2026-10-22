# MB906 — Shared JSON decoding for AppleMusic details

Date: 2026-10-22. Development maintenance; no database schema change.

## Reproduction and correction

AppleMusic's HTTP helper returns a character string. The JSON-LD reader then
passes that string to a decoder expecting UTF-8 bytes. Valid literal accents or
emoji can make artist/type/year/duration/track-count details disappear. The page
title still displays, making the failure look like incomplete upstream metadata.
The same details parse correctly from raw UTF-8 bytes or escaped ASCII JSON.

`Mediabot::JSON::decode_json_payload` shares the MB905 conversion: retain raw
UTF-8 byte input, encode character input once, then use JSON::MaybeXS's decoder.
It is a pure optional export, with no URL/AI dependency, network request, timer,
state or persistence. It returns the decoder's values and still throws on invalid
JSON so callers retain their existing eval/error policies.

```perl
use Mediabot::JSON qw(decode_json_payload);
my $data = eval { decode_json_payload($response_body) };
```

AppleMusic's JSON-LD and iTunes lookup readers use this helper. The lookup keeps
normal byte-response behavior and also accepts already-decoded character input.
Spotify's private helper delegates its existing MB905 conversion to the same
module; no Spotify parser, scalar guard or formatter changes.

Only imports, two AppleMusic decoding calls, and Spotify's private delegation
change in the existing production modules. Other providers remain on their
current byte-oriented paths; their input contracts are not assumed equivalent.
Facade/exports, badges/colors, formats, truncation, cache keys/TTL, pending state,
HTTP/browser ordering and limits, timeouts and worker lifecycle stay unchanged.
No Partyline, schema, migration, production SQL, private config, VERSION, service,
runner or audit tool changes.

## Base and validation

This round uses the MB905 state validated by the user: the original
`snap_mediabot_v3_teuk_20261022_125032.zip` overlaid with the five verified MB905
payloads. The 1,771 reconstructed files match the retained MB905 candidate.
No newer uploaded snapshot is claimed. The server's post-commit VERSION is
unknown and excluded from this package and its preconditions. The installer
checks the affected MB905 file bytes before writing.

Thirteen assertions extend existing case 855, using actual owners in a fresh
Perl process. The new matrix passes 13/13 on the candidate and 6/13 on MB905.
Seven criteria reproduce the Unicode failure; the others protect raw bytes,
escaped JSON and malformed/null handling. Arrays, HTTP and browser-result
fallback, iTunes lookup, two native worker completions and cache reuse are covered.

HTTP replies and the browser result are simulated; IO::Async, fork/pipe,
AsyncWorker, parsers and the completion/cache path are real. Outputs are captured,
and native tests verify no HTTP/browser work in the parent process. There are
no Apple/Spotify requests, actual Chromium process, real IRC output, existing
DB access or public listener in the new fixture.

Thirty-nine decoder vectors match the MB905 Spotify helper's values and
accept/reject behavior, preserving input content and UTF-8 flags. Twenty-seven
nominal AppleMusic metadata vectors match byte/escaped inputs. All 18 MB905
Spotify scenarios pass through the shared helper. Four independent mutations
are detected: missed Unicode encoding, double-encoded bytes, bypassed JSON-LD
reader and bypassed lookup reader.

No numbered case or old assertion is removed. Seven payload paths: four modified,
three new (shared module, fixture and this note). The catalogue stays at 1,156
cases. These checks do not prove the absence of every regression or verify live
AppleMusic/Spotify markup. See QUALIFICATION.md for the full-suite results and
installation/rollback evidence.


## Results

| Check | Local result |
| --- | --- |
| Four syntax checks | OK |
| Targeted URL/music/worker group, 29 files | 941/941, 7 s |
| Security | GO, 37 invariants |
| Startup integrity | OK |
| Full reference, 1,156 files | 30,380 passed + 1 failed / 30,381, 142 s |
| Full candidate, 1,156 files | 30,396 passed + 1 failed / 30,397, 141 s |

The same MB786 updater-rehearsal exit-status failure occurs in both full suites.
The updater and its test are unchanged. Local full suites are not declared green
and no performance gain is claimed. The 16-assertion delta is 13 behavior checks
plus three automatic checks for the new module. The delivered validator requires
the full unfiltered suite to pass on the server, with no MB786 exemption.
