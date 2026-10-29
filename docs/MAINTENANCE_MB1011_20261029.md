# MB1011 — Complete UTF-8 characters in IRC output

## Reproduced defect

The shared IRC splitter already counted UTF-8 character strings correctly,
but treated encoded, unflagged UTF-8 buffers as arbitrary individual bytes.
With 399 ASCII bytes followed by an accented character or emoji, the 400-byte
cut could retain only the first byte of that character. The next IRC frame
started with its continuation bytes. Each frame was invalid UTF-8 even though
concatenating the payloads recovered the original buffer.

This affected real PRIVMSG, NOTICE and CTCP ACTION delivery through the common
splitter, as well as prefix-only output. Existing tests checked concatenated
content and frame lengths but did not decode each raw-input frame separately.

## Correction

Before cutting raw byte input, decode a bounded window with at most budget + 4
bytes. Four look-ahead bytes suffice to complete any UTF-8 character crossing
the proposed boundary. Use the existing character-aware boundary and word-wrap
logic, then return encoded bytes. Input buffers are not consumed or rewritten.

An incomplete or invalid probe that cannot cover the requested budget retains
the legacy raw-byte fallback, without replacement characters or diagnostics.
No whole shrinking tail is decoded on each iteration. Prefix-only operations
inspect only the bounded window. Existing character-string handling, minimum
split budget, default budget, CR/LF/NUL sanitation and output envelopes remain.
For tiny prefix budgets, a character that cannot fit produces an empty prefix
instead of a partial UTF-8 sequence.

Only `Mediabot/IRC/TextBudget.pm` changes at runtime. The public helpers and
sender remain the same; no database, configuration or dependency change is
required.

## Regression evidence

`t/cases/1386_mb1011_raw_utf8_chunks.t` adds eight focused assertions:

- Two-, three- and four-byte characters across 16-, 391- and 400-byte cuts,
  preserving exact bytes and the byte-buffer representation.
- Prefix-only boundaries and tiny budgets, without consuming input.
- Actual PRIVMSG, NOTICE and ACTION wire frames through the normal Output,
  Helpers and Sender path, publicly and privately, for character and raw input.
  Each frame is decoded independently, while byte limits, targets, complete
  content, envelopes and output metrics are checked.
- Legacy non-UTF-8 bytes and raw/character word-wrap and sanitation parity.

Seven assertions fail on the original snapshot; all eight pass after the fix.
Existing tests are neither modified nor removed. Existing performance and
representation contracts are included in targeted qualification.

```bash
perl t/test_commands.pl --filter '1386_mb1011|1302_mb879|1306_mb881|547_mb325|549_mb327|86_module_structure' --progress
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
