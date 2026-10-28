# MB990 — French Trivia integration on the current maintenance tree

Base: snapshot `snap_mediabot_v3_teuk_20261028_125116.zip` plus MB989. The package
also contains a cumulative patch for that snapshot without MB989; it preserves
or installs the exact MB989 correction before adding this feature.

The previously prepared MB984 French source was absent from the latest uploaded
tree. This delivery rebases it onto MB989, retains MB983 stop/cancellation fixes,
MB986 test reductions and MB987–989 fixes, and gives French an explicit opt-in.

## Behavior

- `trivia fr` adds 6,044 OpenQuizzDB French questions, 14 categories and three
  difficulties. `trivia en` selects the existing complete Open Trivia DB path.
  A new game without a language stays English, regardless of main.LANG/chansets.
- The unfinished series retains its language. Each next question is requested
  with `trivia`, as before. `triviastop` keeps its existing Master requirement.
- French answer comparison accepts omitted accents and common ligatures while
  retaining complete-word boundaries and the original accented display answer.
- Persistent TRIVIA_SCORES SQL and the English HTTP/retry/parser implementation
  remain unchanged. Sources share the existing scores without reset or import.
- French catalog selection runs inside the existing asynchronous worker, with
  no API key or network dependency. Source errors are explicit; no silent
  substitution of an English question. Recent ids are excluded per channel
  while a fresh filtered candidate exists.

## Catalog

This is an explicitly archived 2022-02-12 selection from commit
`a16819964d171e40e6652368fc562f3bd27d0c5b` of Zeuh/OpenQuizzDB. It is not a
claim of a current export or factual certification of every question. Data
credits, per-quiz provenance and the full CC BY-SA 4.0 text are included.
No generated translation has been substituted. The catalog was reconstructed
from that source revision and compared byte for byte with the packaged file.

## Validation and operation

- 84 feature assertions cover catalog validation, filters, explicit language,
  English defaults, real registry handlers and SQLite score persistence,
  cancellation, accent matching and one real asynchronous worker round trip.
- Targeted selection: 1,575/1,575 assertions. This replaces the earlier feature's
  457-assertion matrix with representative cases and the existing Trivia suite.
- Security audit: GO, all 37 invariants. Startup integrity and command inventory
  pass. Full-suite results are recorded in the package README.
- Local process rehearsal 1151 fails on the unchanged snapshot here. Process
  identity check 828 is environment-sensitive and is also checked on baseline.

Apply on teuk, run the full suite with --progress, restart dev, then use the
native commit/push script. Afterwards run the native updater on nbot as its
owner with the exact mediabot.conf. Stop its systemd service first and restore
it in an EXIT trap, so an external shell updater cannot race an automatic bot
restart during directory rotation. No other production instance is targeted.
No plugin activation, configuration edit, SQL migration or grant is needed.
