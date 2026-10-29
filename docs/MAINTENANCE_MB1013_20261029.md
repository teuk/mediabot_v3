# MB1013 — Complete Spotify HTML metadata

## Reproduced defect

The Spotify meta reader ended an attribute's content at either an apostrophe or
a double quote, independently of the quote that opened the attribute. Thus a
valid tag such as:

```html
<meta property="og:title" content="L'amour - Toto">
```

produced the title `L` and lost the artist. The same issue affected artist names
and publication years extracted from descriptions. Whitespace around `=` could
also make a valid attribute invisible. A `>` inside a quoted content value ended
the outer tag scan early, and content-like text inside another attribute could
be selected as the actual content.

The failure was reproduced through the real URL dispatcher and AsyncWorker:
the emitted preview was `(Reader) [Spotify] L`, with an unnecessary normal-page
HTTP fallback after the incomplete embed metadata.

## Correction

Read the meta tag while respecting complete quoted values, then parse its
attributes with matching opening/closing quote delimiters. Attribute names and
recognized metadata keys remain case-insensitive; whitespace and attribute
order are accepted. Preserve the first occurrence of a duplicate attribute.

Select `property`/`name` and `content` from their actual attributes. Opposite
quote characters and a quoted `>` stay in the value. Existing title/artist
extraction, description interpretation, HTML entity cleanup, title priority and
generic-shell rejection then receive the complete strings. Empty content
attributes remain ignored, so a later empty tag cannot erase a usable value.

Only `Mediabot/External/Spotify.pm::_spotify_extract_meta` changes at runtime.
The oEmbed/embed/page strategy, JSON metadata reader, duration formatting,
resource identity, pending ownership, badge and worker lifecycle are unchanged.
No database, configuration, schema or dependency change is required.

## Regression evidence

`t/cases/1388_mb1013_spotify_meta_attributes.t` adds seven focused assertions:

- Apostrophes, opposite quotation marks and French title text.
- Attribute order, whitespace, case, duplicate handling and unrelated text.
- A greater-than sign inside a quoted value.
- All three supported description sources, including a complete artist/year.
- The actual lightweight fetch strategy with offline HTTP responses, retaining
  full metadata and avoiding the unnecessary third request.
- The real URL dispatcher, child process, pipe and AsyncWorker completion:
  no parent HTTP or early IRC output, one complete preview to the original
  target, two exact child HTTP destinations and released pending ownership.
- Existing preferred metadata, shell rejection, title fallback, entities and
  preservation of a valid title followed by an empty meta tag.

Six assertions fail on the original snapshot; all seven pass with the fix.
Existing tests are neither modified nor removed. HTTP responses are simulated
locally; no external service, SQL server or IRC server is contacted.

```bash
perl t/test_commands.pl --filter 'spotify|1388_mb1013|module_structure|external_module|external_entrypoint' --progress
perl t/test_commands.pl --progress
perl tools/security_audit.pl --quiet
perl tools/startup_integrity_check.pl --quiet
perl tools/mb_architecture_inventory.pl --check docs/generated/COMMAND_INVENTORY.md
```

The delivery README records the actual full-suite result and comparisons with
the unchanged snapshot. The supplied procedure runs the complete suite before
restarting only `mediabot@dev.service`, then calls the native `commit.sh` flow.
No remote service, commit, push or production deployment was performed during
this local qualification.
