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
  needs the dedicated ALLOW_TOPIC gate on top of apply + ALLOW_IRC.
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
- Full sources: `examples/` — fourteen shipped scripts, all covered by the
  test suite (statically, by real execution, and end to end through the
  apply pipeline).
