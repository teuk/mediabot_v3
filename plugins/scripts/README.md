# Mediabot external script plugins

Mediabot can route selected public commands to trusted **Perl, Python or Tcl**
scripts through `Mediabot::Plugin::ScriptDryRun`. The module name is historical:
it supports both a no-side-effect **dry-run** mode and an explicitly gated
**apply** mode.

## What users can do

Once an administrator enables routes, IRC users invoke external commands exactly
like normal Mediabot commands. The repository ships nine command examples:

| Command route | Language | Purpose |
|---|---|---|
| `hello` | Perl | minimal reply/log contract |
| `pyhello` | Python | minimal reply/log contract |
| `tclhello` | Tcl | dependency-free reply/log contract |
| `proll` | Python | bounded dice roller |
| `p8ball` | Tcl | Magic 8-Ball |
| `pchoose` | Perl | random choice helper |
| `pcalc` | Python | safe AST-based arithmetic calculator |
| `premind` | Perl | one-shot reminder demonstrating timer actions |
| `pcountdown` | Python | countdown demonstrating timers + per-route config |

The `p` aliases are intentional. Mediabot already has richer internal `roll`,
`8ball`, `choose` and `calc` commands; routing the same names in apply mode would shadow
those handlers.

## Configuration

```ini
[plugins]
AUTOLOAD=1
ENABLED=Mediabot::Plugin::ScriptDryRun

[plugins.ScriptDryRun]
COMMANDS=hello,pyhello,tclhello,proll,p8ball,pchoose,pcalc,premind,pcountdown
ROUTES=hello=examples/hello_perl.pl, pyhello=examples/hello_python.py, tclhello=examples/hello_tcl.tcl, proll=examples/roll.py, p8ball=examples/eightball.tcl, pchoose=examples/choose.pl, pcalc=examples/calc.py, premind=examples/remind.pl, pcountdown=examples/countdown.py
ACTION_MODE=apply
ALLOW_IRC=yes
APPLY_REQUIRE_SCOPE=yes
```

For observation without real output, use:

```ini
ACTION_MODE=dry-run
ALLOW_IRC=no
```

`APPLY_REQUIRE_SCOPE=yes` should remain enabled. It prevents an unscoped fallback
script from owning every public command in apply mode.

## Script protocol

Mediabot launches the selected interpreter without a shell and writes one JSON
object to STDIN. A typical envelope is:

```json
{
  "protocol": "mediabot-script-v1",
  "event": "public_command",
  "data": {
    "channel": "#example",
    "target": "#example",
    "nick": "alice",
    "command": "pchoose",
    "args": ["tea", "|", "coffee"]
  }
}
```

The script writes one JSON object to STDOUT:

```json
{
  "protocol": "mediabot-script-v1",
  "ok": true,
  "actions": [
    {"type": "reply", "text": "alice: I choose: coffee"},
    {"type": "log", "level": "info", "text": "choice completed"}
  ]
}
```

Supported planned action types are `reply`, `notice`, `log` and `timer`.
Reply/notice output requires both `ACTION_MODE=apply` and `ALLOW_IRC=yes`.

### Timer actions

```json
{"type": "timer", "name": "my_reminder", "delay": 30}
```

In apply mode, a `timer` action re-runs the **same script** after `delay`
seconds (1–3600) with the event `timer`. The deferred invocation receives the
original `channel`/`target`/`nick`/`command`/`args` data plus `timer_name` and
`timer_delay`, so a script can branch on `event` to produce its deferred
output. Deferred `reply`/`notice` actions pass through the same `ALLOW_IRC`
and channel-scope guards as direct output.

Timer guardrails:

- a timer-invoked run can **never** schedule further timers (no chains);
- a `name` already pending is rejected until it fires or is cancelled;
- at most 4 timers may be pending globally in the current bot process;
- timers are in-memory only and do not survive a bot restart or plugin reload;
- pending timers are cancelled when the plugin is unloaded or replaced.

`examples/remind.pl` (routed as `premind`, Perl) is the reference implementation
of this lifecycle: confirmation + timer on the command, delivery on the
deferred `timer` event, one pending reminder per nick.
`examples/countdown.py` (routed as `pcountdown`) is its Python counterpart
and additionally demonstrates per-route configuration.

## Channel events (join/part/topic/kick)

Beyond public commands, the bridge can route channel lifecycle events to
scripts, strictly opt-in and one script per event:

```ini
EVENTS=join=examples/greet.pl, topic=examples/topicwatch.pl, part=examples/partwatch.tcl, kick=examples/kickwatch.pl
EVENT_COOLDOWN=10
```

All four routes above ship as reference examples: `examples/greet.pl` (Perl)
welcomes a joining nick in the originating channel, `examples/topicwatch.pl`
(Perl) acknowledges topic changes using the event-specific `topic` envelope
field, and `examples/partwatch.tcl` (Tcl) says goodbye on `part`, quoting the
departure reason from the event-specific `message` field, and
`examples/kickwatch.pl` (Perl) traces moderation on `kick` using the
kick-specific fields (`nick` = operator, `kicked` = victim, `message` =
reason). Kick events are suppressed when the bot is the kicker or the
victim.
When routed to an unexpected event, these examples log a warning and stay
silent on IRC — a reference event script never spams a channel because of a
config mistake.

The routed script is executed with the matching event name (`join`, `part`,
`topic` or `kick`); the envelope carries `channel`, `nick` and, where relevant,
`ident`, `host`, the part or kick `message`, the new `topic`, or the kick
victim in `kicked` (`args` is always present and empty). Output goes through
the same `ACTION_MODE`, `ALLOW_IRC` and channel-scope guards as command
output, and event scripts may arm timers.

Event guardrails:

- no `SCRIPT` fallback: an event without an `EVENTS` route never runs;
- the bot's own join/part/topic events never trigger scripts, and kick is
  suppressed when the bot is the kicker or the victim;
- at most one run per event per channel per `EVENT_COOLDOWN` window
  (1-3600s, default 10): join/part bursts from netsplits and kick sweeps are
  counted and ignored, never forked;
- an `EVENTS` route is an explicit scope, so `APPLY_REQUIRE_SCOPE` adds no
  extra gate here.

## Per-route configuration

Each route — command or event — can carry its own configuration:

```ini
CONFIG_premind=max_delay=1800
CONFIG_pcountdown=max_seconds=600
CONFIG_join=welcome=Bienvenue sur ce canal,
```

The value is a `key=value; key2=value2` list (';' separated, so values may
contain commas). Configuration is attached to ROUTES/EVENTS entries only: a
command allowed through COMMANDS but served by the `SCRIPT` fallback has no
route name, so a CONFIG_ key for it is silently ignored — give the command an
explicit route if it needs configuration. Keys are `[A-Za-z0-9_.-]` (max 64 chars), values are capped
at 512 chars and at most 20 keys per route are kept; invalid pairs are
rejected with a log line, never silently truncated. The validated map is
injected into the JSON envelope as `data.config` only when non-empty, and it
travels with deferred timer runs. Scripts must always keep a default:

```perl
my $config  = ref($data->{config}) eq 'HASH' ? $data->{config} : {};
my $welcome = $config->{welcome} // 'welcome,';
```

`data.config` is the only structured envelope field: one level deep, scalar
values only. Every other field keeps the flat scalar/array contract.

## Safety boundary

The bridge validates script paths, prevents directory/symlink escape, chooses a
known interpreter, uses no shell, bounds STDIN/STDOUT/STDERR, enforces a timeout,
validates the JSON response and caps the number/size of actions. Scripts are
trusted local extensions, not a sandbox for untrusted code.

## Partyline checks

```text
.plugins
.scriptdryrun status
.scriptdryrun last
.scriptdryrun config
.scriptdryrun timers
.scriptdryrun canceltimers
```

`timers` lists armed script timers (name, remaining/total delay, origin
channel/nick/command, script). `canceltimers` cancels every armed timer and
frees its pending slot; it never creates or executes anything.
