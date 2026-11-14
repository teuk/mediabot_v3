# Clone, understand and contribute to Mediabot

Mediabot is a Perl IRC application. The default `master` branch is **3.6dev**;
**3.5** remains the published stable release. Choose a development checkout for
contributions and the [verified release](https://github.com/teuk/mediabot_v3/releases/tag/3.5)
for a production installation.

You can work on commands, parsers and plugins without connecting a bot to IRC,
creating a Mediabot database or possessing provider keys. The tests below use
fixtures; some create private temporary files, SQLite databases and child
processes. They still need the Perl dependencies.

## 1. Clone into a development directory

Use an ordinary account, never a production checkout:

```bash
git clone https://github.com/teuk/mediabot_v3.git
cd mediabot_v3
git switch -c refactor/my-change
```

Do not run `./configure` just to run the offline tests. That wizard is the path
for a real installation: it creates configuration and initializes its database.
For that separate task, follow [the first-channel guide](FIRST_CHANNEL_3.6DEV.md).

## 2. Prepare Perl dependencies

The CI uses Perl 5.40. On Debian 13, install the build tools and native headers
with the system administrator, then return to the ordinary account:

```bash
sudo apt-get update
sudo apt-get install -y perl cpanminus build-essential pkg-config libmariadb-dev curl ca-certificates
```

Use the repository's `cpanfile` for developer dependencies, with a local module
tree. It is ignored by Git. Hailo is installed separately, as in the existing
CI workflow; SQLite is required for the isolated database fixtures.

```bash
cpanm --notest --local-lib local --installdeps .
cpanm --notest --local-lib local DBD::SQLite
export PERL5LIB="$PWD/local/lib/perl5${PERL5LIB:+:$PERL5LIB}"

if ! perl -MHailo -e 'exit 0'; then
  cpanm --notest --local-lib local Hailo ||
    cpanm --notest --local-lib local \
      https://cpan.metacpan.org/authors/id/A/AV/AVAR/Hailo-0.75.tar.gz
fi

bash install/cpan_install.sh --verify-only
perl -MDBD::SQLite -e 'print "SQLite test driver available\n"'
```

These are dependency installations; the application tests are run explicitly
next. The supported system installer's runtime module list remains in
`install/cpan_install.sh`, and CI mirrors it with `cpanfile` plus Hailo.
Do not create a second dependency list in a new helper.

In a new shell, set `PERL5LIB` again from the checkout root if using this local
tree. A missing module is a setup failure to resolve, not a reason to skip tests.
Do not copy credentials, brains, logs or configuration from production.

## 3. Run one useful offline slice

For the game domain extracted in MB951:

```bash
perl -I. -It/lib -c Mediabot/Games/Trivia.pm
perl -I. -It/lib -c Mediabot/Games/QuoteGame.pm
perl t/test_commands.pl --filter 'trivia|quotegame|mb326|mb610' --progress
```

The filter matches case filenames. List the selection when choosing a different
slice, or use the existing fast lane for a wider first check:

```bash
perl t/test_commands.pl --filter 'trivia|quotegame' --list-selected
perl t/test_commands.pl --fast --progress
```

The fast lane is not the complete acceptance suite. Use the project's runner;
`prove -lr t` does not correctly execute every historical closure-style case.
`--list-selected` lists the chosen cases; it still loads the runner's basic Perl
dependencies.

For the built-in small games, the source owners are `Games/Chance.pm` and
`Games/Duel.pm`. Their historical command names remain imported through
`UserCommands`; the independently activated `playful-v3` plugin keeps its own
implementation and policy. A built-in refactor does not enable that plugin.

```bash
perl -I. -It/lib -c Mediabot/Games/Chance.pm
perl -I. -It/lib -c Mediabot/Games/Duel.pm
perl t/test_commands.pl --filter 'mb425|mb562|mb563|mb610|mb411|playful' --progress
```

For channel statistics, use the two domain modules and their existing archive,
calendar and failure-semantics tests:

```bash
perl -I. -It/lib -c Mediabot/Stats/Activity.pm
perl -I. -It/lib -c Mediabot/Stats/History.pm
perl t/test_commands.pl --filter 'stats|wordcount|streak|mb574|mb575|mb576|mb577|mb578|mb579|mb627|mb655|mb738' --progress
```

The registry still imports the historical command names through
`UserCommands.pm`. Change the implementation in `Stats/Activity.pm` or
`Stats/History.pm`; keep transport hooks in that facade available at call time.
The history reader, archive retention rules and SQL scopes remain owned by
`Helpers.pm` and `ChannelLog/Reader.pm`. Source-inspection tests must follow an
extracted command to its new owner; keep their original assertions.

For user-facing birthdays and last-seen lookups:

```bash
perl -I. -It/lib -c Mediabot/Users/Birthdays.pm
perl -I. -It/lib -c Mediabot/Users/Seen.pm
perl t/test_commands.pl --filter 'birthday|seen|horoscope|mb399|mb434|mb497|mb500|mb576|mb578' --progress
```

`Users/Birthdays.pm` owns the birthday command and its Gregorian/local-calendar
helpers. The horoscope continues to call the existing helper name through the
facade. `Users/Seen.pm` owns online, persisted and archived last-seen lookups;
keep its requested-channel scope and wildcard escaping when changing it.
`Mediabot/User.pm` remains the account/authentication object.

For account-level queries and profile views:

```bash
perl -I. -It/lib -c Mediabot/Users/Levels.pm
perl -I. -It/lib -c Mediabot/Users/Profiles.pm
perl t/test_commands.pl --filter 'user_id_level|usercommands_lookup|userinfo|moduser|greet|mb455' --progress
```

`Users/Levels.pm` owns the four existing exact level lookups and their original
failure/empty-input return values. `Users/Profiles.pm` owns `userinfo`,
`userstats` and `greet`: the first two keep their existing Administrator and
Master checks. The greet query keeps its requested channel and original public
or private reply. `userinfo` reads password presence, never the password value.
The authentication object and policy still live in `User.pm` and `Context.pm`.

For horoscope and achievement presentation:

```bash
perl -I. -It/lib -c Mediabot/Users/Horoscope.pm
perl -I. -It/lib -c Mediabot/Users/AchievementView.pm
perl t/test_commands.pl --filter 'horoscope|achievement|mb621|mb957' --progress
```

`Users/Horoscope.pm` owns the command and zodiac helpers; HTTP/parsing and compact
forecast rendering stay in `External/Horoscope.pm`. Calendar validation still
comes from Birthdays through the existing facade hook. The Games gate, local
daily random sequence, language and persistent progress hooks retain their
existing behavior. `Users/AchievementView.pm` owns the catalogue, rankings and
progress views; durable storage, identity and unlock policy stay in
`Achievements.pm`. Detailed progress and the catalogue retain their private
reply routes, including the secret-achievement visibility rules.

Both modules keep their historical `UserCommands` command/helper aliases.
The existing SocialHistory goal formatter still resolves that facade at call
time. When editing either owner, keep the transport and progress hooks late
bound; do not add SQL persistence or provider logic to these views.

For channel activity and public capability/state views:

```bash
perl -I. -It/lib -c Mediabot/Stats/Radar.pm
perl -I. -It/lib -c Mediabot/Diagnostics/Commands.pm
perl t/test_commands.pl --filter 'mb958|mb348|mb627|dispatch|module_structure' --progress
```

`Stats/Radar.pm` owns the live activity radar and its bounded 1–30 day history
view. `Diagnostics/Commands.pm` owns `features`/`capabilities`/`caps` and
`observatory`/`obs`, with their existing chanset/default and uptime/energy helpers.
The capability summary remains private; the two observatory lines and radar
remain on the requested channel. The historical `UserCommands` names and bot
methods still point to those owners. Outputs and the shared number formatter
are resolved through the facade at call time.

These read views do not own diagnostic collection or publication. Keep the
existing `Diagnostics/Channel.pm`, `Activity.pm`, `Plugins.pm`, `Publisher.pm`
and mbweb readers as their own boundaries. Moving a public command does not
enable or reconfigure diagnostics on any channel.

## 4. Find the owner of a change

| Concern | Start here | Related test filenames |
| --- | --- | --- |
| Startup, connections and event wiring | `mediabot.pl` | `runtime`, `startup`, `module_structure` |
| Built-in command registration and help | `Mediabot/Mediabot.pm`, `Mediabot/BuiltinCommandCatalog.pm`, `Mediabot/CommandRegistry.pm` | `catalogue`, `registry`, `dispatch` |
| Context and authorization boundaries | `Mediabot/Context.pm`, `Mediabot/Auth.pm` | `context`, `auth`, `login` |
| Trivia game and worker adapter | `Mediabot/Games/Trivia.pm` | `trivia`, `mb319`, `mb653` |
| Quote guessing and its timer | `Mediabot/Games/QuoteGame.pm` | `quotegame`, `mb326`, `mb445` |
| Dice, coins, choices, 8ball and slap | `Mediabot/Games/Chance.pm` | `mb425`, `mb562`, `mb563`, `playful` |
| Duels, their karma changes and achievement hooks | `Mediabot/Games/Duel.pm` | `mb610`, `playful`, `mb411` |
| Remote trivia parsing and HTTP | `Mediabot/External/OpenTriviaDB.pm` | `trivia`, `mb394`, `mb395` |
| Channel statistics, rankings and activity charts | `Mediabot/Stats/Activity.pm` | `stats`, `mb574`, `mb578`, `mb627` |
| Word counts, activity streaks, last messages and ranked sayings | `Mediabot/Stats/History.pm` | `wordcount`, `streak`, `topsay`, `mb426`, `mb455`, `mb655`, `mb738` |
| Live activity radar and bounded daily history | `Mediabot/Stats/Radar.pm` | `mb958`, `mb348`, `mb627` |
| Public capability/state commands and their private/public reply routes | `Mediabot/Diagnostics/Commands.pm` | `mb958`, `dispatch`, `mb621` |
| Channel affinity from hours, vocabulary, karma and adjacent messages | `Mediabot/Stats/Affinity.pm` | `compat`, `mb427`, `mb575`, `mb576`, `mb578`, `mb610` |
| Exact account/channel level lookups | `Mediabot/Users/Levels.pm` | `user_id_level`, `usercommands_lookup`, `moduser` |
| Account statistics, userinfo and channel greet views | `Mediabot/Users/Profiles.pm` | `userinfo`, `greet`, `mb455` |
| Horoscope command, zodiac calendar and achievement views | `Mediabot/Users/Horoscope.pm`, `Mediabot/Users/AchievementView.pm` | `horoscope`, `achievement`, `mb621`, `mb957` |
| Birthday command and local-calendar helpers | `Mediabot/Users/Birthdays.pm` | `birthday`, `mb399`, `mb434`, `horoscope` |
| Online, persisted and archived last-seen lookups | `Mediabot/Users/Seen.pm` | `seen`, `mb497`, `mb500`, `mb576`, `mb578` |
| Memories and annual/community history | `Mediabot/SocialHistory.pm`, `Mediabot/Memory/Search.pm` | `memory`, `yearbook`, `onthisday` |
| Notes, reminders, polls and factoids | `Mediabot/CommunityState.pm` | `note`, `remind`, `poll`, `factoid` |
| Conversation and spontaneous output | `Mediabot/Hailo/`, `Mediabot/Spark/`, `Mediabot/Conversation/` | `hailo`, `spark`, `conversation` |
| Shared transport and async ownership | `Mediabot/IRC/`, `Mediabot/CommandAsync.pm`, `Mediabot/AsyncWorker.pm` | `delivery`, `async`, `worker` |
| Media previews | `Mediabot/External/` | provider name, e.g. `reddit` or `spotify` |
| Channel observations and web projection | `Mediabot/Diagnostics/`, `contrib/mbweb/` | `partyline`, plus `contrib/mbweb/test/` |
| Plugin lifecycle and capabilities | `Mediabot/PluginManager.pm`, `Mediabot/Plugin/` | `plugin`, `v3` |
| Deployment and installation | `install/`, `.github/workflows/` | `install`, `schema`, `updater` |

This is a navigation map, not a promise that every subsystem is fully split.
`UserCommands.pm`, `Helpers.pm` and other large modules still contain legacy
responsibilities. Prefer a domain owner when it exists; avoid adding unrelated
logic to a compatibility facade.

### Trace one real command

1. Find its catalogue entry and handler in `Mediabot/Mediabot.pm`.
2. Follow the exported command to its implementation. For example,
   `mbTrivia_ctx` is imported through `UserCommands` and implemented in
   `Games::Trivia`; quote guessing is in `Games::QuoteGame`.
3. Read its `Context` checks and shared output/worker boundaries before editing.
4. Find the matching cases in `t/cases/` and run them with the native runner.

`docs/generated/COMMAND_INVENTORY.md` is generated from the real catalogue and
help. Verify or regenerate it with the existing tool when changing those:

```bash
perl tools/mb_architecture_inventory.pl --check docs/generated/COMMAND_INVENTORY.md
# Only when changing the catalogue/help:
perl tools/mb_architecture_inventory.pl --write docs/generated/COMMAND_INVENTORY.md
```

### Trace sayings and affinity

`userTopSay_ctx` is implemented in `Stats::History`; `mbCompat_ctx` is in
`Stats::Affinity`. Both retain their historical `UserCommands` imports and
`Mediabot` methods. The catalogue and asynchronous command dispatch still
call the same entry points.

`topsay` requires an authenticated Administrator or higher. It keeps its
literal nickname escaping and SQL limit, sends at most a summary to the
channel, and sends paginated details by notice. `compat` remains scoped to
the requested channel and its `Games` setting. Its historical hours and word
samples use the shared live/archive reader; its recent adjacent-message
query stays on the live table. Achievement progress and IRC hooks resolve
through the existing facade at call time.

Use this offline slice when editing either command or its boundaries:

```bash
perl t/test_commands.pl --filter 'topsay|compat|usermodinfo|mb427|mb348|mb455|mb575|mb576|mb578|mb610|dispatch|module_structure' --progress
```

### Why the old game names still exist

MB951 moves implementation, not the public contract. `UserCommands` imports the
same command/helper names, and `Mediabot` keeps its existing public methods.
Existing dispatch and plugins do not need a new registration path.

The game modules resolve the historical transport, achievement and source hooks
at call time. Nested fetch/reset/timer calls retain the old hook namespace too.
This preserves existing local overrides and the established asynchronous test
boundaries. It is a deliberate compatibility edge, not permission to add new
business logic to `UserCommands` or to load a running bot from a domain module.

SQL, state keys, scoring, Unicode boundaries, timers, grants, output and remote
request budgets keep their behaviour in this extraction. A refactor must not
silently smuggle in a gameplay fix or a new default.

## 5. Submit a change someone else can review

Start with an observable example, preserve the existing contract, and add a
behaviour regression when changing behaviour. For an extraction, retain native
scenarios and move source-location checks to the actual owner rather than
copying old implementations into tests.

For the final candidate, run:

```bash
perl t/test_commands.pl --progress
perl tools/security_audit.pl --quiet
perl tools/startup_integrity_check.pl --quiet
git diff --check
```

Run mbweb's own tests if changing its JavaScript. Record the exact commands,
results and any environment limitation. Do not weaken a test, preload a fake
service identity or exclude an unexplained failure to get a green result.

A contribution should say what changed, why, what remains compatible and how it
was checked. See [CONTRIBUTING.md](../CONTRIBUTING.md) for the PR checklist,
[the plugin workshop](PLUGIN_WORKSHOP.md) for a first package, and
[the command inventory](generated/COMMAND_INVENTORY.md) for existing entry points.

## Qualification campaign

Follow [the five-step qualification roadmap](QUALIFICATION_ROADMAP.md).
`python3 tools/qualification/run.py --lane preflight --output /tmp/mb-preflight`
checks committed HEAD in a disposable source clone. Use a new report directory
and pass `--perl-lib "$PWD/local/lib/perl5"` when using local dependencies.
This does not install modules or replace precommit checks of working changes.


For an explicit disposable dependency build, the qualification runner also supports
`--provision`. See [MB1292](QUALIFICATION_ROADMAP.md#mb1292--disposable-provisioning-and-observed-dependencies)
for prerequisites, evidence, timeouts and remaining reproducibility limits.

The qualification fast/full lanes also require `node`, `tclsh` and `pgrep`
(Debian packages `nodejs tcl procps`). Dashboard projections, Tcl sidecars and
the disposable updater rehearsal execute these native tools. The runner checks
them before starting the suite; a missing tool is `unavailable`, not a test pass.
The Perl-only preflight lane retains its existing scope. Fresh CI installs these
packages explicitly and records their versions in its retained evidence.

`python3 tools/qualification/run.py --lane irc --output /tmp/mb-irc-UNIQUE`
qualifies committed HEAD using existing native case 1313, including the local
socket journeys. The full lane runs the same case. It requires normal native
Perl dependencies; it never starts mediabot.pl or loads deployment configuration.
See MB1297 in the qualification roadmap for seams and remaining scope limits.

The IRC lane also exercises a missing-table SQL fault in an in-memory SQLite
fixture, a throwing diagnostic sink, and recovery. Native rules, dispatch and
wire output remain active; only the private fixture database is modified. The
fresh workflow watches the native journey case and its supporting fixtures.

The same IRC lane now covers public `!version` with injected HTTP 503, a blocked
HTTP fixture stopped by the real worker watchdog, and recovery. Native child
processes and pipes are exercised; no external HTTP request is made. The test
checks callback diagnostics, exact IRC replies and OS child collection.


### Bounded saturation measurement (MB1300)

For a committed snapshot on a prepared host, run
`python3 tools/qualification/run.py --lane load --output /tmp/mb-load-report`
with a new output path. Both load and full lanes retain `saturation.json` alongside
report.json. The full lane measures before running the complete suite.
For an uncommitted candidate, `perl tools/qualification/saturation.pl NEW_REPORT_JSON`
measures the working files and records their hashes; it refuses an existing file.
This local socket probe tests three bounded bursts, overflow, FIFO recovery,
PING responsiveness and virtual expiry. Manual drain and injected time do not
measure production throughput or long endurance. Resource and latency samples
are observational; the roadmap lists remaining qualification limits.


### Real-time queue recovery (MB1301)

The saturation report now includes `timed_recovery`: two channels, two messages
per channel, real native two-second countdowns and rearming. The default two
cycles add about eight seconds to the standalone measurement and native IRC case.
No drain callback or clock is injected in this phase. The AntiFlood decision
remains controlled by the fixture; this is not a production traffic benchmark.

For a bounded two-minute repetition on working sources:

```bash
perl tools/qualification/saturation.pl /tmp/mb-timed-new.json --timed-cycles 30
```

The output must not already exist. Cycle counts are restricted to 1..300; the
upper bound takes about twenty minutes. Full/load qualification uses the default
two cycles and preserves the same JSON. The maintainer delivery runs thirty
cycles before the full suite and before its final commit/push. On slower hosts,
allow up to ten seconds per drain; this is a test deadline, not a production SLO.


### Closing the bounded endurance gate (MB1302)

Run this separately from routine full/load lanes, on a prepared development host:

```bash
report="$(mktemp -d /tmp/mediabot-endurance.XXXXXXXX)"
perl tools/qualification/saturation.pl "$report/saturation.json" --timed-cycles 300 > "$report/saturation.tap" &&
python3 tools/qualification/assess_endurance.py "$report/saturation.json" --output "$report/endurance.json"
```

Allow about twenty minutes. Progress appears on stderr every fifteen cycles
(about one minute); TAP remains in the report directory. The assessor compares
source hashes against its repository, requires all 300 samples and 1,200 timed
messages, unchanged post-drain notifiers/fds, PONG <= 2s, native drain >= 3.6s,
final notifier cleanup and exact original burst/expiry counts. After ten warmup
cycles, peak RSS may grow at most 16,384 KiB above the warmup median. That is an
explicit conservative local test envelope, not an inferred production SLO or
proof of zero leakage. /proc resource measurements are required for this gate.
Malformed, short, missing or source-mismatched evidence returns 3 (unavailable);
violated measured budgets return 2 (failed); only a complete pass returns 0.
The assessment records its input and assessor hashes and refuses an existing
output. Do not edit thresholds after a failure just to obtain a green result.

The maintainer delivery runs targeted tests, this single long workload and its
assessment, then one full suite; existing commit.sh commit/push is last. Routine
full/load qualification retains its short two-cycle measurement. See the roadmap
for the bounded closure and excluded hours-long/production fairness claims.


### Representative command contracts (MB1303)

`perl t/test_commands.pl --filter '1313_mb883' --progress` includes the shared
contract matrix in `t/lib/MB1297LocalIRCProbe.pl`. Each row declares an IRC frame,
caller, permission state, expected exact wire replies and stored words. Native
registry dispatch, Context, handlers, Sender and SQLite remain active. The same
ordinary NOTICE barrier closes each exchange before checking extra replies.

The twelve scenarios cover public/private echo, Unicode and empty arguments,
public spike and its absent private registration, then addbadword authentication,
grant/revocation, a second caller, absent private registration, failed SQL prepare
and successful recovery. Authorization lookup and audit sinks are fixtures; this
qualifies handler consumption of the current identity/role, not login or session
storage. Persisted channel ID and Unicode word are checked together. Add rows to
this runner for a concrete regression; do not infer support in an unregistered
command scope or force all commands to share one presentation policy.

The 300-cycle endurance gate is already accepted on teuk for MB1302. This delivery
requires targeted and full tests only, ending with noninteractive commit/push.
No new twenty-minute run is needed for the representative contract matrix.
