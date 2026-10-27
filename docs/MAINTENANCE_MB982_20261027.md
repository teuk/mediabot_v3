# MB982 — Keep hyphenated karma targets intact

## Reproduced defect

The karma vote parser excluded `-` from nickname candidates. For a nickname
such as `Alice-Bob`, explicit voting first confirmed that the complete nickname
was present, then synthesized `alice-bob++` and passed it to the automatic
parser. That parser could match `bob++` and change Bob's score instead. If Bob
was absent, the intended vote was silently ignored.

The same suffix matching affected automatic votes and could redirect a
hyphenated self-vote into an unrelated account's score. Unanchored matching
could also accept a short nickname suffix of an overlong token.

## Change

Allow hyphens in the existing two-to-32-character candidate and require its
token to begin at the start of the message or after whitespace. Use a lazy
candidate so the first terminal vote operator is separated from its following
punctuation. The existing right boundary still rejects embedded/unfinished
operators. Internal and trailing hyphens remain part of the full nickname,
including when the final operator is `--`.

Keep the existing channel presence check, normalization, self-vote/away-name
checks, cooldown and brigade rules, per-message cap, SQL, watcher notifications,
achievement hooks and memory/database histories. Only the recognition patterns
and their comments change in runtime code. No configuration, schema, grant or
plugin activation change is required.

## Regression coverage

`t/cases/1358_mb982_karma_hyphenated_targets.t` invokes the three native
facades and the real public `karma` command registry. It uses actual SQLite
UPSERTs and persisted karma history, with an independent connection observing
the scores. A test-only bridge translates the unchanged MariaDB SQL dialect.

Coverage includes positive/negative operators, explicit short/doubled signs,
internal/doubled/trailing hyphens, the 32-character boundary, absent and overlong
targets, self-votes including away names, case changes during cooldown,
cooldown recovery, terminal punctuation, the three-token cap and the sixth
distinct voter triggering brigade protection. Assertions verify the exact
target in scores, watcher notices, achievements and both histories, and retain
other accounts/channels.

The regression contains 836 assertions: 380 fail against the supplied
snapshot and all pass after the fix. Full-suite/audit results are recorded in
the delivery README. No running bot or SQL server is contacted by the test.
