# MB905 — Preserve Unicode Spotify metadata

Date: 2026-10-22. Development maintenance, with no database schema change.

## Reproduced failures

The HTTP content helper can return a character string. The JSON decoder expects
UTF-8 bytes. Literal non-ASCII text in valid oEmbed, __NEXT_DATA__ or JSON-LD can
therefore be rejected silently by the existing eval boundary. Titles or optional
metadata disappear, or an unnecessary page fallback is attempted. Escaped JSON
can work for the same metadata, making the issue depend on response encoding.

Reference fields are another failure: JSON objects, arrays or booleans can pass
through text cleaning and appear as HASH(...), ARRAY(...) or 1 in the visible
metadata, preventing a valid fallback title or artist from being selected.

After rejecting an invalid structured album name, the broad legacy album regex
can borrow a later artist name from a sibling object. The fix prevents this when
the album was already processed structurally, while preserving legacy unparsed
album extraction, including nested cover metadata before the name.

## Change

A private Spotify JSON adapter encodes character strings once and preserves raw
UTF-8 byte inputs. All three JSON readers use it. Existing invalid-JSON handling
stays inside the same eval boundaries. Text cleaners reject references. Entity
name is considered when its title cleans to an unusable value. A local marker
keeps an unusable structured album from invoking the broad regex on that document;
other structured sources in the document can still supply a valid album.

Only four existing Spotify function bodies, one private helper and its Encode
import change. Facade/exports, output formatting, green Spotify badge/reset,
300-character display cap, URL/pending identity, HTTP order and limits, timeouts,
worker ownership and completion behavior remain unchanged. No Partyline code,
schema, migration, production SQL, private configuration, VERSION, service,
test runner or audit tool changes.

## Regression protection

Eighteen assertions extend existing case 854 with a fresh-process fixture:

- Literal and escaped Unicode in oEmbed, NEXT_DATA, JSON-LD and page fallback.
- Invalid title/artist/album reference fields and malformed JSON.
- Raw UTF-8 byte input and the legacy nested-album fallback.
- Five real fork/pipe AsyncWorker runs, including Unicode and malformed optional
  fields, preserving caller, target, single output and pending-state release.

HTTP is replaced with deterministic local replies; Chromium calls throw and IRC
output is captured. Native worker tests leave the parent HTTP call list empty.
No Spotify request, real IRC output, existing database or public listener is used.
The 18 criteria pass on the candidate; 7 already pass on the reference, including
escaped JSON, invalid-JSON handling, raw-byte compatibility and a native escaped
control. Eleven failed criteria on the reference reproduce the corrected behavior.

Fifty-one separate nominal metadata/HTTP-trace comparisons match the reference,
including escaped Unicode, multiple artists, optional values and nested albums.
The final guard preserves the original regex for unparsed data, and the shipped
compatibility scenario protects nested cover metadata preceding an album name.

Five mutations are detected: missing Unicode encoding, double-encoding byte
input, admitted reference fields, ignored valid entity name and sibling-derived
album. No numbered case is added; the catalogue remains at 1,156 files. Existing
assertions are preserved. These checks do not prove the absence of every
regression or verify today's live Spotify markup. See the package's
QUALIFICATION.md for full-suite results and installation/rollback evidence.


## Validation results

| Check | Local result |
| --- | --- |
| Two changed-module/fixture syntax checks | OK |
| Targeted URL/Spotify/worker group, 29 files | 928/928 |
| Security audit | GO, 37 invariants |
| Startup integrity | OK |
| Full reference, 1,156 files | 30,361 passed + 2 failed / 30,363, 129 s |
| Full final candidate, 1,156 files | 30,379 passed + 2 failed / 30,381, 129 s |

Both full suites encounter the same MB786 updater exit-status failure and MB647
process-identity observation failure. The corresponding code and tests are
unchanged. A separate same-process comparison of the actual Doctor collectors
observes a live child via kill 0 but no /proc entry, with identical absent owner
facts in both trees. The local full suites are not declared green and no speed
improvement is claimed. The delivered validator requires the entire unfiltered
suite to pass on the server, including both checks, with no exemption.
