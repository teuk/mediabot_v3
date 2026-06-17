# Mediabot external script plugins

Mediabot can route selected public commands to trusted **Perl, Python or Tcl**
scripts through `Mediabot::Plugin::ScriptDryRun`. The module name is historical:
it supports both a no-side-effect **dry-run** mode and an explicitly gated
**apply** mode.

## What users can do

Once an administrator enables routes, IRC users invoke external commands exactly
like normal Mediabot commands. The repository ships six examples:

| Command route | Language | Purpose |
|---|---|---|
| `hello` | Perl | minimal reply/log contract |
| `pyhello` | Python | minimal reply/log contract |
| `tclhello` | Tcl | dependency-free reply/log contract |
| `proll` | Python | bounded dice roller |
| `p8ball` | Tcl | Magic 8-Ball |
| `pchoose` | Perl | random choice helper |

The `p` aliases are intentional. Mediabot already has richer internal `roll`,
`8ball` and `choose` commands; routing the same names in apply mode would shadow
those handlers.

## Configuration

```ini
[plugins]
AUTOLOAD=1
ENABLED=Mediabot::Plugin::ScriptDryRun

[plugins.ScriptDryRun]
COMMANDS=hello,pyhello,tclhello,proll,p8ball,pchoose
ROUTES=hello=examples/hello_perl.pl, pyhello=examples/hello_python.py, tclhello=examples/hello_tcl.tcl, proll=examples/roll.py, p8ball=examples/eightball.tcl, pchoose=examples/choose.pl
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
`timer` is validated but is not implemented for application yet. Reply/notice
output requires both `ACTION_MODE=apply` and `ALLOW_IRC=yes`.

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
```
