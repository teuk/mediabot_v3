# MB1010 — Complete poll vote numbers

## Reproduced defect

`mbVote_ctx` accepted `\d+` before Perl numeric comparisons. That regular
expression accepts Unicode decimal digits, while Perl arithmetic can convert
only the ASCII prefix of a mixed token. For example, `2١` passed validation as
option 2 with a numeric warning. It could replace an existing vote for option 1,
increment the vote metric, append a successful audit and change the winner.
The previous `$` end anchor also accepted a trailing newline in direct calls.

## Correction

Validate the entire option number with `\A[0-9]+\z` before numeric comparison.
Malformed tokens receive the existing private vote syntax notice. They do not
cast or replace a ballot, emit a successful vote announcement, increment the
vote metric or append a successful vote audit.

The accepted ASCII syntax, including leading zeroes, is unchanged. Legitimate
vote changes and weighted tallies still work. Validation remains after lazy
expiry, so a due poll closes under its existing strict `>` deadline rule before
any vote can be changed. No database, configuration or schema change is needed.

## Regression evidence

`t/cases/1385_mb1010_poll_vote_tokens.t` invokes the real native public command
registry and Context with controlled time and captured wire, metrics and audit.
Eight assertions cover:

- Malformed first votes and replacement votes in ordinary and weighted polls,
  including mixed digits, Arabic/fullwidth digits, a trailing newline and
  existing invalid numeric forms. Ballots, other channels, arguments, metrics
  and audit are compared with their pre-call state; warnings are captured.
- Whole ASCII numbers with leading zeroes, valid changes, weighted winner
  selection and withdrawal after a refused replacement.
- Lazy expiry before malformed input, preserving the existing ballots.

Five assertions fail on the unchanged snapshot; all eight pass with the fix.
No existing tests are removed or modified. The delivery README records the
actual targeted/full-suite and environment comparison results.

## Qualification and deployment

```bash
perl t/test_commands.pl --filter 'poll|1385_mb1010|module_structure' --progress
perl t/test_commands.pl --progress
perl tools/security_audit.pl --quiet
perl tools/startup_integrity_check.pl --quiet
perl tools/mb_architecture_inventory.pl --check docs/generated/COMMAND_INVENTORY.md
```

The supplied procedure applies the patch idempotently, runs the complete suite,
then restarts only `mediabot@dev.service`. A successful check permits the normal
`commit.sh` workflow, including its confirmation prompt, VERSION update, commit
and push. No remote service, GitHub push or production deployment was performed
during this local qualification.
