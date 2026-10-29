# MB1015 — Reparo: preserve Unicode in plugin storage 🧭🪄

## Reproduced defect

The plugin storage writer serialized JSON as a Perl character string and
printed it to a raw file. When any key or value contained a character above
U+00FF, Perl warned about a wide character and encoded the whole document as
UTF-8. The existing byte-oriented JSON reader did not reverse that conversion.

For example, `Été — 東京 🪄` came back as corrupted text. Even an unrelated
accented field in the same document was changed. Unicode hash keys could no
longer be looked up by their original names. The same disk boundary serves
legacy store actions and the namespaced API v3 key/value repository.

## Narrow fix and compatibility

The writer now requests JSON escapes for characters outside Latin-1. The
result is byte-safe for the existing raw file and reader. This deliberately
keeps the exact historical representation of ASCII and Latin-1 documents;
changing the reader to guess UTF-8 would reinterpret some legitimate old data.

The shared store validator uses the same representation when enforcing the
16 KiB limit. The bound therefore describes actual serialized bytes, including
Unicode escapes, at both action planning and the disk boundary. An oversized
new document is rejected before replacing existing state or updating metrics.

Only these runtime points change:

- `Mediabot/PluginManager.pm::_store_plugin_data`: byte-safe serialization.
- `Mediabot/ScriptActionRunner.pm::_validate_storage_object`: matching byte count.

Reads, file names, object shape, repository revisions/conflicts, action gates,
0600 temporary-file/rename publication, metrics, symlink rejection and missing
directory behavior retain their existing contracts. No SQL schema, dependency,
plugin capability or private configuration changes are introduced.

This prevents corruption on new writes. It does not guess or automatically
repair text already corrupted by the old writer. No live state is migrated,
cleared or rewritten by applying the patch.

## Regression coverage

`t/cases/1390_mb1015_plugin_storage_unicode.t` contains eight assertions;
six fail with the original runtime:

- Native file round-trips preserve mixed Unicode keys/values, booleans, nulls,
  numbers, literal zero and arrays without a wide-print warning.
- Repeated read/write cycles preserve text and physical bytes.
- The real API v3 repository and disk sink preserve Unicode across revision
  increments and unrelated updates; stale commits remain write-free conflicts.
- A serialized 16,384-byte Unicode document is accepted and readable.
- A 16,385-byte document is refused by action planning and direct storage,
  preserving the prior file, metrics and absence of temporary files.
- Old ASCII/Latin-1 files, including ambiguous UTF-8-looking octets and large
  Latin-1 values, retain exact values and bytes after a read/write cycle.
- Native action application stores Unicode and continues to its authorized reply.
- Reads retain the existing symlink and missing-directory guards.

All files live in temporary test directories. No database, IRC server or
external service is contacted. No existing test is modified or removed.

## Validation and deployment

Run the focused storage/action tests, the full native suite with `--progress`,
the security audit, startup integrity check and command inventory. The delivery
README records actual local results, including any failures reproduced on the
unchanged snapshot.

The supplied procedure applies the patch, runs the full checks, restarts only
`mediabot@dev.service`, then invokes the native `commit.sh`. This delivery does
not itself deploy remotely, commit or push.
