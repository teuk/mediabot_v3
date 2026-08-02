# Mediabot script cookbook — patterns by task and language

Practical recipes for writing `mediabot-script-v1` plugin scripts. The
[README](README.md) is the reference (protocol, keys, guardrails); this page
is the "how do I do X" companion. Every snippet below is distilled from a
shipped example — the full, tested source is always the file named in the
recipe.

The protocol is language-neutral: same envelope in, same JSON contract out.
Perl and Python read the envelope with their standard JSON module; the Tcl
examples use a dependency-free regexp style (fine for simple fields; use
tcllib's json for exotic input).

## 1. The minimal contract (start here)

Read stdin as JSON, branch on `event`, print one JSON object with `protocol`,
`ok` and `actions`. Nothing else is required.

- Perl: `examples/hello_perl.pl`
- Python: `examples/hello_python.py`
- Tcl: `examples/hello_tcl.tcl`

```perl
my $payload = eval { decode_json(do { local $/; <STDIN> } // '') } || {};
my $event   = $payload->{event} // 'unknown';
my $data    = ref($payload->{data}) eq 'HASH' ? $payload->{data} : {};
# ... build @actions ...
print encode_json({ protocol => 'mediabot-script-v1',
                    ok => JSON::PP::true, actions => \@actions });
```

Defensive parsing is part of the contract: never trust a field to exist or to
be a scalar — every shipped example guards with `ref()`/`isinstance` checks.

## 2. Validate arguments, reply with usage

Validate first, act second, and make the usage reply show the EFFECTIVE
bounds. Full pattern: `examples/remind.pl` (Perl), `examples/countdown.py`
(Python).

```python
if seconds < MIN_SECONDS or seconds > max_seconds:
    actions.append({"type": "reply",
                    "text": f"{nick}: usage: {command} <seconds 1-{max_seconds}> [label]"})
```

## 3. Parse untrusted input strictly (anti-abuse limits)

Command arguments are user input on a public channel: parse with a strict
grammar, cap everything, and treat "reject" as the default branch.

- `examples/roll.py` — a real regex grammar (`2d6+3`) with hard caps on dice
  count, sides and modifier, and a summarized display beyond a threshold.
- `examples/calc.py` — arithmetic on an AST walk (never `eval()`), a
  whitelist of operators, and depth/size limits.
- `examples/choose.pl` — splitting and trimming free-form alternatives while
  bounding their number and length.
- `examples/eightball.tcl` — the dependency-free Tcl envelope-extraction
  style reused by every Tcl example.

## 4. Arm a timer, deliver later

The timer lifecycle (mb525): the command run emits a confirmation reply plus
`{"type": "timer", "name": ..., "delay": N}`; when it expires the SAME script
is re-run with event `timer` and the ORIGINAL data plus
`timer_name`/`timer_delay`.

References: `examples/remind.pl` (Perl), `examples/countdown.py` (Python).

Key ideas the references demonstrate:

- **State survives by rebuilding from the original args** — the protocol is
  deliberately stateless, and the deferred run receives the original args
  again, so parse the same way twice.
- **Derive the timer name from the nick**, restricted to the protocol charset
  and length (`[A-Za-z0-9_.-]`, max 64): one pending timer per nick, and a
  duplicate is rejected by the bridge (visible in `.scriptdryrun timers`).
- **Never emit a timer from the `timer` branch** — chains are rejected
  upstream anyway.

```perl
my $safe_nick = $nick;
$safe_nick =~ s/[^A-Za-z0-9_.-]/_/g;
my $timer_name = substr('remind_' . $safe_nick, 0, 64);
```

## 5. React to a channel event

Events are opt-in (`EVENTS=` route, no `SCRIPT` fallback) and each event
carries its own extra fields:

| Event | Extra envelope fields | Reference |
|---|---|---|
| `join`  | `ident`, `host` | `examples/greet.pl` (Perl) |
| `part`  | `message` (departure reason) | `examples/partwatch.tcl` (Tcl) |
| `topic` | `topic` (new topic, may be empty) | `examples/topicwatch.pl` (Perl) |
| `kick`  | `kicked` (victim), `message` (reason); `nick` is the operator | `examples/kickwatch.pl` (Perl) |

For join-time moderation, `examples/gatekeeper.pl` shows the kick action
(mb554): substring matching on the joining nick (no user-supplied regex by
design), total silence on normal joins, an unarmed configuration that never
kicks, and the full ALLOW_KICK gate chain advertised in its header. Since
mb564 it can also close the door first: `ban=yes` in the route config emits
a `ban` action (mask `nick!*@*`) before the kick, behind the ALLOW_BAN gate
— kick-only remains the default.

Rules every event script must live with:

- the cooldown means you do **not** see every occurrence (netsplits, bursts);
- the bot's own events never reach scripts (for `kick`, both roles);
- replies land in the originating channel and cannot target another one.

## 6. Stay silent when misrouted

An operator typo in `EVENTS=` must not turn into channel spam. Every shipped
event reference logs a warning and emits **no reply** when it receives an
event it was not written for:

```perl
push @actions, { type => 'log', level => 'warning',
    text => "greet: unexpected event '$event' (route me to join only)" };
```

## 7. Read per-route configuration (with a mandatory default)

The envelope also carries a read-only `data.network` snapshot (users,
users_max, channels, servers, operators, age_seconds) rebuilt fresh at
every run — a deferred timer sees the network as it is NOW, while its
`data.config` stays as it was when armed.

`CONFIG_<route>` lands in the envelope as `data.config` (the primary structured
field — one level, scalar values), and it is present only when non-empty, so
**always keep a default**:

```perl
my $config  = ref($data->{config}) eq 'HASH' ? $data->{config} : {};
my $welcome = $config->{welcome} // 'welcome,';
```

When configuration touches a bound, it may only TIGHTEN the protocol limits —
never widen them. References: `examples/greet.pl` (`welcome`),
`examples/remind.pl` (`max_delay`), `examples/countdown.py` (`max_seconds`).
Note: an armed timer fires with the config snapshot it was armed with;
`.scriptdryrun reload` affects new runs only.

For all three features combined in one file — an event arming a configured
timer whose deferred run rebuilds everything from the original envelope —
see `examples/topicreminder.pl` (route it as an alternative to the simple
`topic` reference). It also demonstrates the one-pending-timer-per-name
semantic honestly: while a reminder is pending, a new topic change cannot
arm a second one. With `CONFIG_topic=mode=restore` it switches from
re-posting the topic to RE-SETTING it through the topic action — the
canonical demonstration that per-route config can select between action
types, and that the topic action's triple gate (apply + ALLOW_IRC +
ALLOW_TOPIC) applies to deferred runs exactly as to immediate ones. Its readable timer name includes a stable digest suffix so
sanitization or truncation cannot make ordinary channel names share a slot.

## 8. Survival rules (what the bridge enforces around you)

- Delays are bounded to 1..3600s; reply/notice text is bounded upstream;
  the topic action targets the originating channel only (300 chars max) and
  needs the dedicated ALLOW_TOPIC gate on top of apply + ALLOW_IRC; the kick
  action follows the same shape with ALLOW_KICK (IRC nick <= 30, reason
  <= 120 UTF-8 bytes) and the bridge refuses to kick the bot itself.
- IRC output requires `ACTION_MODE=apply` **and** `ALLOW_IRC=yes`; in dry-run
  your actions are validated and planned, never applied.
- Keep IRC-bound text plain ASCII in reference-quality scripts: exotic
  punctuation survives the encoder but is a debugging trap.
- JSON escaping and length caps are the bridge's job — do not reimplement
  them (badly) in the script.
- Scripts are trusted local extensions, not a sandbox: the safety boundary
  protects the bot from script MISTAKES, not from a malicious script author.

## 9. Where to look next

- Reference: [README](README.md) — protocol, keys, partyline tooling.
- Full sources: `examples/` — fifteen shipped scripts, all covered by the
  test suite (statically, by real execution, and end to end through the
  apply pipeline).

## 10. Plugin v2: declare your commands in a sidecar manifest (mb586-mb592)

Everything above still applies — the envelope, the actions, the survival
rules. What changes with plugin v2 is HOW your script gets wired to a
command: no configuration route needed. Put a JSON manifest next to the
script and let the PluginManager mount it:

    plugins/scripts/examples-v2/coin.py
    plugins/scripts/examples-v2/coin.py.manifest.json

    {
      "api": 2,
      "name": "coin",
      "version": "1.0",
      "description": "Coin flips with an anti-abuse cap.",
      "commands": {
        "coin": { "help": "coin [n] - flip 1..10 coins.", "level": 0 }
      }
    }

Then, from the partyline (Owner):

    .plugins loadscript examples-v2/coin.py
    Loaded script plugin 'coin' (examples-v2/coin.py, commands: coin)

The contract, in six rules:

1. **The sidecar is mandatory and validated.** Missing, malformed, oversized
   (8 KB cap) or colliding manifests are refused with the precise reason —
   nothing is half-mounted. `name` must match the script basename (or the
   registration name you pass to loadscript).
2. **`level` is 0 or a USER_LEVEL description.** `0` = public. A string such
   as `"Master"` makes the auth bridge check the caller's level BEFORE your
   script is even executed (see `fortunes` in examples-v2/fortune.pl). The
   semantics are the bot's own: smaller is stronger, an Owner passes a
   Master command.
3. **Reply, notice and log actions apply.** Mounted script commands run
   with `apply + allow_irc`: normal IRC replies/notices and bounded log
   actions work. Topic, kick, ban and unban stay refused without their
   dedicated gates; timer actions have no scheduler in this lifecycle.
4. **Failures stay sober.** A crashing script, an invalid envelope or a
   failed action never spams the channel: one short notice, the details go
   to the bot log.
5. **The lifecycle is the plugin lifecycle.** `.plugins loaded` shows your
   commands, `enable`/`disable` silences them without unloading,
   `reload <name>` re-reads the sidecar (a broken edit leaves the previous
   instance active), `unload <name>` unmounts everything.

6. **Declared events are real subscriptions (mb593).** For a sidecar
   script, each name in `"events"` must belong to the routable whitelist —
   `public_command_observed`, `channel_join_observed`,
   `channel_part_observed`, `channel_topic_observed`,
   `channel_kick_observed`, `channel_nick_observed` (nick = old nick,
   `new_nick` = the new one), `channel_quit_observed` (real quits only,
   never netsplits; both are network-wide — no channel field), and
   `plugin_cron_observed` — and the PluginManager subscribes for you: your
   script is executed with that event name and a bounded observed context
   (channel, nick, message, topic, kicked, is_self... depending on the
   event; `public_command_observed` also carries command and scalar args).
   Same action gates as commands; failures go to the log only — an
   event has no caller to notify. `disable` silences the subscription,
   `unload` removes it. In-process Perl plugins are unchanged: they
   subscribe themselves in register() and their list stays informational.

       { "api": 2, "name": "greeter", "version": "1.0",
         "events": ["channel_join_observed"] }

   `plugin_cron_observed` fires once per minute (Eggdrop's bind time,
   reborn): the context carries minute, hour, dow (0=Sunday), mday and
   month, and YOUR script decides whether this minute matters — return
   `ok` with an empty action list otherwise (pattern 6). A daily 09:00
   announcement is a two-line test on hour and minute.

7. **Sidecar config: defaults declared, conf overrides (mb600).** A
   `"config"` block in the sidecar declares the author's defaults (up to
   32 UPPERCASE keys, scalar values, 512 bytes each — fail-closed at
   validation). The operator overrides any key from the bot's conf as
   `plugins.<name>.<KEY>`, no script edit needed. The effective map is
   snapshotted at load (reload re-reads sidecar AND overrides — the same
   philosophy as route config) and delivered to your script as
   `data.config`. See greeter.tcl: set `plugins.greeter.GREETING` to
   replace the welcome pool with your own line (`%s` receives the nick).

8. **Persistent storage: the bot writes, your script asks (mb601).** Your
   script never touches the filesystem. To persist state, emit a `store`
   action: `{"type": "store", "data": {...}}` — a JSON object, at most 3
   levels deep, 256 keys, 16 KB serialized, ONE store per run (the whole
   object replaces the previous one; read-modify-write). The bot writes
   it atomically to `<DATA_DIR>/<plugin>.json` (conf `plugins.DATA_DIR`,
   default `plugin-data/`). On every later dispatch your script receives
   the current object as `data.storage` — read FRESH each time, unlike
   the snapshotted `data.config` (a stale counter helps nobody).
   Concurrent runs: last write wins. JSON booleans are valid storage
   leaves. `.plugins info` shows the file size without creating the storage
   directory; sensitive config keys are redacted. `.plugins cleardata <name>`
   (Owner) wipes only a validated plugin slug. Route-v1 scripts have no store
   sink: their store actions fail explicitly.

Working three-language examples live in `plugins/scripts/examples-v2/`:
`fortune.pl` (Perl, includes a Master-gated command), `coin.py` (Python,
anti-abuse cap), `lart.tcl` (Tcl, dependency-free — in loving memory of
every Eggdrop that ever ran one), and `greeter.tcl` (Tcl, the event
showcase: no command at all, one declared `channel_join_observed`, an
is_self guard, and a warm welcome for everyone else).
