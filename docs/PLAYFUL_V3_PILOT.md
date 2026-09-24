# Playful v3 development pilot

MB745 is the first visible API v3 product proof. It migrates `8ball`, `abbrev`,
`choose`, `flip`, `morse` and `roll`, and adds the `quiet_magic` autonomous
ritual. Nothing is loaded or enabled automatically.

## Safety model

| State | Commands | Ritual |
| --- | --- | --- |
| package absent or disabled | historical built-in behavior | stopped |
| channel `off` | historical built-in behavior | no invocation |
| channel `observe` | v3 shadow, historical visible answer | handler runs, output suppressed |
| channel `on` | v3 answer | allowed only when `ritual_enabled=1` |
| unload | exact historical registry entries restored | job removed |

The pilot must begin on one development channel. Do not configure a second
channel until the observation window is reviewed.

## Partyline procedure

As an authenticated Owner:

```text
.plugins discoverv3
.plugins loadv3 playful-v3 irc.reply,irc.notice,irc.channel_message,scheduler.jobs
.plugins policy playful-v3 #development observe language=fr ritual_enabled=0 ritual_every=4 ritual_style=subtle
.plugins enable playful-v3
.plugins info playful-v3
```

Exercise the six commands. The historical replies remain visible while the v3
handlers run silently. Review plugin failure and observe counters, then promote
the same single channel:

```text
.plugins policy playful-v3 #development on language=fr ritual_enabled=0 ritual_every=4 ritual_style=subtle
```

After command parity is accepted, the autonomous proof can be enabled. A value
of `ritual_every=1` is useful for a short supervised test; restore `4` for the
normal cadence of at most one line per hour because the job interval is 15
minutes.

```text
.plugins policy playful-v3 #development on language=fr ritual_enabled=1 ritual_every=1 ritual_style=subtle
.plugins policy playful-v3 #development on language=fr ritual_enabled=1 ritual_every=4 ritual_style=subtle
```

The ritual emits self-contained comic micro-events and never asks users to
answer.

## Immediate rollback

Either command returns the channel to historical behavior immediately:

```text
.plugins policy playful-v3 #development off
.plugins disable playful-v3
```

To remove the pilot and restore the original catalogue entries:

```text
.plugins unload playful-v3
```

Since MB766, successful Owner lifecycle changes are held by the core API v3
boot ledger. Restart therefore restores the last committed posture; it is not a
rollback mechanism. Unload remains the definitive rollback because it removes
the package from the next boot ledger. No database or private configuration
migration is involved.

## MB778 persistent development promotion

MB778 promotes `playful-v3` only on development `#test`. It enters `observe`
before `on`, grants exactly `irc.reply`, `irc.notice`, `irc.channel_message` and
`scheduler.jobs`, and reuses MB745's six-command reversible parity evidence.
The accepted policy keeps `language=fr`, `ritual_every=4`,
`ritual_style=subtle` and the typed default `ritual_enabled=false`.

A clean restart must restore six mounted commands, six saved handlers, one
registered job, one `on` policy and zero failures. Every pre-existing ledger
entry must remain byte-for-byte equivalent. Source stays default-off and no
production channel is touched.
