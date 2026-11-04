# MB1098 — One outgoing badword cache per channel

## Fault and visible behavior

The sender used the target's exact spelling as its five-minute badword cache
key. The channel registry already uses lowercase names. `#tEsT`, `#TEST` and
`#test` could consequently hold different confirmed lists for the same room.
The add/remove handlers only deleted the registered display spelling and the
spelling supplied to the command, leaving a third spelling stale.

An empty list loaded through one spelling could keep accepting a newly added
badword until its TTL expired. During a database failure, another spelling
also missed the previously confirmed list, entering the historical initial
lookup fallback instead of retaining the room's known rules.

## Change

`IRC::Sender::_badwords_for_channel` reads and publishes under `lc($target)`,
the identity already used by the channel registry. PRIVMSG and ACTION therefore
share one list and one refresh age across display spellings. SQL still binds
the original target; the outgoing target and history spelling are untouched.
No IRC casemapping change is introduced.

After a successful INSERT or DELETE, the native add/remove handlers invalidate
the lowercase registered identity as well as their historical display/typed
keys. Existing/missing-word no-ops and failed writes retain confirmed rules.

The five-minute TTL, complete-read requirement, error-before-finish check,
bounded failure diagnostic, metrics and last-confirmed fallback remain in
place. An initial SQL failure still follows the existing diagnostic-and-send
policy when no confirmed rules exist. The normal dev restart clears old
in-memory cache spellings before this code serves traffic.

## Native verification

Reuse `1306_mb881_irc_output_policy.t`, its private SQLite database, DBI error
injection and real IRC output paths. The channel-name fixture uses NOCASE to
represent the existing case-insensitive MariaDB channel-name column; it also
provides the badword primary key needed by the native mutation commands.

Four grouped assertions cover:

- 32 mixed-case read scenarios: PRIVMSG/ACTION, fresh/expired cache, prepare,
  execute, first-fetch and partial-fetch faults, with RaiseError off and on.
  Rejected output creates no wire message, history event or normal LIVE log.
  The confirmed cache and its age survive and a fresh cache avoids another read.
- Four native command cycles through an authenticated Master context: warm an
  empty list, add using a different spelling, immediately reject the word,
  repeat the existing-word command, remove using another spelling, then accept
  the word immediately and repeat the missing-word command. Another channel's
  cache remains intact; wire/history targets and SQL binds retain their spelling.
- Eight real failed-write controls using SQLite abort triggers: returned errors
  and RaiseError exceptions cannot discard the confirmed list or change rows.

Remove nine copied-filter assertions from the old MB162 case. Keep its six
unrelated antiflood checks. Net change: five fewer assertions, no new test file,
child process, timeout, dependency or database migration.

The counterproof runs these native tests against the snapshot's application
files: all four new groups fail. The corrected application passes them.

## Operator procedure

Use the package verification and apply script as `mediabot` on `teuk.org`.
The script checks exact cumulative contents, runs targeted tests and the full
suite visibly with `--progress`, then security/startup/inventory checks. It
stages qualified changes, restarts only `mediabot@dev.service`, requires a new
PID stable for ten seconds and invokes the interactive native `commit.sh`.

VERSION is not part of the patch. `commit.sh` continues its normal 3.8dev
version planning. A failed gate stops before the commit; a stable process
alone does not establish IRC reconnection.
