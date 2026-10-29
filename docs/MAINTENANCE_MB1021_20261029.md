# MB1021 — General MixCloud profile cards without changing show previews

## Request

After confirming the MB1020 mix preview on dev `#radiocapsule`, the operator
requested an informative response for `https://www.mixcloud.com/leekid/` too.
The badge and successful mix card should remain intact.

## Change

Add a one-segment public profile parser and a shared link selector. The
original `url_info` show parser stays byte-identical. Profile metadata comes
from the single matching public API object, with exact key and optional URL
identity validation, using the existing HTTP and worker limits.

The detached profile result retains only name, optional location, biography,
mix count and follower count. Missing fields are omitted rather than replaced
with invented zeroes; valid zero counts remain visible. A blank display name
can use the supplied username. Public counters are grouped with spaces.

The profile renderer keeps the existing badge and clips name and biography
within one sanitized 400-wire-byte line. The show renderer's existing path,
title, author and duration remain unchanged. Profile and show cache keys stay
separate. No worker, cache, delivery policy, chanset, schema, migration,
configuration or dependency change is introduced. An existing +MixCloud flag
continues to govern both card types without another activation.

## Qualification

Eight focused assertions cover profile aliases, reserved/unsafe paths, Unicode
and optional metadata, exact identity, HTTP limits, compact output, actual
AsyncWorker/router delivery of a profile and show together, distinct caches,
deduplication and revocation. The fourteen original MB1020 assertions remain
unchanged and are run alongside them. The new cases also run on the unchanged
MB1020 source to document its lack of profile support.

The supplied public profile and show API endpoints were fetched directly with
the new Perl code and rendered locally. This adds no claim about new live IRC
profile delivery; only the earlier show delivery was reported by the operator.

```bash
perl t/test_commands.pl --filter 'mb1021|mb1020|url|spotify|applemusic|reddit|chanset|diagnostic|module_structure' --progress
perl t/test_commands.pl --progress
perl tools/security_audit.pl --quiet
perl tools/startup_integrity_check.pl --quiet
perl tools/mb_architecture_inventory.pl --check docs/generated/COMMAND_INVENTORY.md
```

The delivery README records actual results and any failures reproduced on the
unchanged source. The operator procedure keeps full-suite progress visible,
stops on errors, restarts dev only after success and uses native commit.sh.
The root README, playRadio(), YouTube details and MB1020 test file are unchanged.
