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
sudo apt-get install -y perl cpanminus build-essential pkg-config libmariadb-dev
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

## 4. Find the owner of a change

| Concern | Start here | Related test filenames |
| --- | --- | --- |
| Startup, connections and event wiring | `mediabot.pl` | `runtime`, `startup`, `module_structure` |
| Built-in command registration and help | `Mediabot/Mediabot.pm`, `Mediabot/BuiltinCommandCatalog.pm`, `Mediabot/CommandRegistry.pm` | `catalogue`, `registry`, `dispatch` |
| Context and authorization boundaries | `Mediabot/Context.pm`, `Mediabot/Auth.pm` | `context`, `auth`, `login` |
| Trivia game and worker adapter | `Mediabot/Games/Trivia.pm` | `trivia`, `mb319`, `mb653` |
| Quote guessing and its timer | `Mediabot/Games/QuoteGame.pm` | `quotegame`, `mb326`, `mb445` |
| Remote trivia parsing and HTTP | `Mediabot/External/OpenTriviaDB.pm` | `trivia`, `mb394`, `mb395` |
| Channel statistics, rankings and activity charts | `Mediabot/Stats/Activity.pm` | `stats`, `mb574`, `mb578`, `mb627` |
| Word counts, activity streaks and last messages | `Mediabot/Stats/History.pm` | `wordcount`, `streak`, `mb426`, `mb655`, `mb738` |
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
