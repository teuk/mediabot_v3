# Partyline internal task shell

MB1031 adds a session-local interactive console for the existing Mediabot
Scheduler and shared AsyncWorker engine. Enter from Telnet or DCC partyline:

```text
.command
mediabot:/> ps
mediabot:/> cd workers
mediabot:/workers> ls
mediabot:/workers> show w12
mediabot:/workers> kill w12
mediabot:/workers> cd ../schedulers
mediabot:/schedulers> ls | grep -i radio
mediabot:/schedulers> stop s4
mediabot:/schedulers> start s4
mediabot:/schedulers> exit
Chat mode. Type .command to return to the internal shell.
```

Use actual IDs from your listing. `w12` and `s4` above are examples.

## Live refresh and listing navigation

MB1033 adds private live observation through the existing Scheduler:

```text
.command #radiocapsule
mediabot[#radiocapsule]:/> watch 5 ps slow
... refreshed observations every five seconds ...
<Enter>
Watch output stopped.
mediabot[#radiocapsule]:/> who | sort -r
mediabot[#radiocapsule]:/> next
mediabot[#radiocapsule]:/> prev
mediabot[#radiocapsule]:/> refresh
```

`watch [seconds] command` defaults to five seconds and permits 5–60. Supported
commands are ps, jobs, ls, status, channels, channel, topic and who; their existing
literal read filters work. The initial query is validated and rendered before
registration. Mutations, nested watch, plugins/chansets/diagnose and arbitrary
commands are rejected: no SQL/provider work is scheduled by watch.

Only one watch belongs to a connection. It runs for at most five minutes, with
an independent refresh-count budget and a 16 KiB UTF-8 frame cap. Any input stops
it before ordinary dispatch and the rate limiter, including Enter or `watch off`.
The next command then runs normally. A new watch replaces the old one. Expiry
or observation failure stops the watch with a private fixed notice. There is no
screen editor or redraw of partially typed client-side input; frames are labelled
line-oriented output. Existing chat/console background suppression remains active.

Each watch appears as `partyline.shell.watch.N` in global ps. Its lifetime uses
the native Scheduler's timer and stop/remove operations, not a second timer
framework. Stopping that schedule from another operator stops refresh; its
registration is removed on the owning session's next input or disconnect.
The watch never changes the inspected tasks. Cache/context/role/stream ownership
is checked before rendering and again before delivery. Disconnect, role change,
fd reuse or reentrant replacement cannot deliver an old private observation.
Captured query data is released on teardown. If native scheduler removal fails,
output is still revoked and the failure is logged privately; ps retains the
native-owned registration for inspection rather than hiding a cleanup failure.

`next`, `prev` and `refresh` reuse the last successful listing's command and
literal filters. These are **live reads**, not immutable snapshots: changing
nick/task counts can move rows or make a page unavailable. Use the original
command to return to a valid page if the listing shrinks. Navigation is refused
after changing directory or selected channel identity. It does not repeat task
mutations. A resource ls listing is normalized to its equivalent ps command.

MB1032 makes shell sessions quiet: incoming partyline broadcasts, chat,
presence and generic command announcements are discarded until exit. Existing
`.console` hooks also suspend delivery without changing the requested level.
Exit resumes future output; suppressed events are never queued for replay.
An explicit `.console off` or level change inside the shell remains in effect.
Direct command responses and explicit disconnect/error responses still work.

## Channel context

```text
.command #radiocapsule
mediabot[#radiocapsule]:/> channel
mediabot[#radiocapsule]:/> who | sort -r | head 5
mediabot[#radiocapsule]:/> plugins
mediabot[#radiocapsule]:/> chansets | grep MixCloud
mediabot[#radiocapsule]:/> diagnose
mediabot[#radiocapsule]:/> use #test
mediabot[#test]:/> topic
mediabot[#test]:/> use -
mediabot:/> status
```

Use `channels` to discover registered channel-cache names. Selection is private
to this connection and resolves the canonical cached name with its database ID.
It does not JOIN, send a message or change a setting. Unknown or ambiguous
identities fail without replacing the current context. Channel commands check
the selected ID again; a purged/recreated same-name channel needs reselection.
If a fresh database diagnostic disagrees with the selected cached identity, it
is refused until the channel cache is refreshed and that channel is reselected.
There is no automatic default channel. Bare `.command` retains this connection's
previous selection; `use -` explicitly clears it.

`channel`, `topic` and `who` expose cached metadata/nicks, not a fresh IRC query.
An unavailable join-state observation stays unknown. `plugins` reuses the safe
loaded API v3 channel diagnostic projection; legacy policy remains unknown.
`chansets` shows the native diagnostic's flag catalogue, not every possible
setting or effective defaults. `chansets` and `diagnose` invoke the existing
read-only channel diagnostic, including its parameterized synchronous database
reads; other new context observations do not query SQL. Diagnostic/database
failures retain unavailable/error states rather than fabricated empty success.

**Task inspection and actions remain GLOBAL.** Selecting a channel does not
filter ps or restrict kill/start/restart to that channel: workers currently lack
reliable per-channel ownership metadata. The listing/help/context output says so.

## Commands

| Command | Behavior |
| --- | --- |
| `help` or `?` | Concise built-in guide |
| `pwd`, `cd [path]` | Navigate `/`, `/workers`, `/schedulers`; `..` and `.` work |
| `ls [path]` | Resource directories or tasks in the selected directory |
| `ps` / `jobs` | All tracked tasks; active workers first, longest durations first |
| `ps workers`, `ps schedulers`, `ps slow` | Filter by owner; slow means at least one second |
| `ps running`, `ps stopped`, `ps failed` | Active/armed tasks, disabled schedules, or retained scheduler callback exceptions |
| `ps all 2` | Next listing page; at most twenty rows per page |
| `show <id>` / `cat <id>` | State, deadline/PID/progress count or scheduler timing/ticks |
| `kill <id>` / `stop <id>` | Request worker cancellation, or disable future scheduler ticks |
| `start <s-id>`, `restart <s-id>` | Use the scheduler's native lifecycle |
| `history`, `!!`, `!number` | Last twenty commands, with non-rebound numbered replay |
| `history clear` | Clear shell history without reusing old sequence numbers |
| `complete [prefix]` | Text suggestions for commands, directories and active IDs |
| `channels [page]`, `use #channel`, `use -`, `context` | Discover/select a registered channel or inspect/clear context |
| `channel`, `topic`, `who [page]` | Cached channel description/timezone/join observation, topic, nicks |
| `plugins [page]`, `chansets [page]`, `diagnose [page]` | Existing safe channel observations and diagnostic catalogue |
| `status` | Global process uptime, IRC connection, tracked worker/scheduler counts |
| `cd -`, `clear`, `help [command]` | Previous successful directory, terminal clear, focused command help |
| `watch [5..60] command`, `watch off` | Bounded cached observation; any input stops it |
| `next`, `prev`, `refresh` | Reuse the last live listing, filters and context |
| `exit` | Return to ordinary partyline chat without disconnecting |

Quoted arguments and backslash escaping are supported. Read listings accept up
to two literal filters: `ps | grep -i "radio lookup" | head 5`. Pipes may be
adjacent to words. `grep` uses literal substring matching, with optional `-i`;
`head` and `tail` accept 1–50. `sort` and `sort -r` order the rendered rows
lexically. Read filters also work on channels/who/plugins/chansets/diagnose.
Filters are validated before the listing or action starts;
mutating commands cannot be piped. No OS command, substitution, redirect or
general-purpose interpreter is invoked. This is a line-oriented shell; textual
`complete` supplies suggestions, without claiming a terminal TAB/arrow editor.

Existing dot commands remain usable, including `.quit`. `.command off` is an
additional way back to chat. Bare unknown commands in shell mode stay private
and produce help guidance instead of being broadcast as partyline chat.
Generic dot-command announcements from shell sessions stay private too; an
explicit native command with its own side effect/presence announcement retains
that command's behavior for ordinary chat recipients. Dot-command arguments are
not silently rewritten to use the selected channel.

History entries bind their channel name/ID at recording time. Replaying one in
another context is refused; type it explicitly there. `history clear` clears
only shell history, not the separate native `.history` or on-disk logs.

## Observation and action semantics

Workers receive process-local monotonic logical IDs, separate from OS PIDs.
Snapshots reveal only labels, PID, elapsed time, timeout, state and progress
count. They contain no callback, payload, private error detail or configuration.
The registry weakly references workers and removes completed registrations
before consumer completion. Inherited fork state and foreign loops cannot be
used to observe/cancel parent jobs through the registry API.

Worker `kill` requests cancellation using its existing TERM/KILL and reaping
logic. The console reports a request, not a fabricated completed stop. Use ps
to observe its disappearance. The originating operation receives its ordinary
worker-cancelled result; it may publish its existing failure response.

Scheduler IDs belong to registrations, so removing/recreating the same task
name yields another ID. Start/stop/restart retains the registration's ID.
Duration fields measure completed callback elapsed time: last, maximum and
total, independent of how long a callback-started async child later takes.
Replacing a task during a callback cannot contaminate the replacement's stats.

An enabled scheduler is armed, not continuously executing. Stopping it disables
future ticks; it does not cancel workers already started by previous ticks.
Those workers have their own IDs. Synchronous Perl code blocking the event loop
cannot be interrupted from a console on that loop. These are elapsed/callback
durations, not per-task CPU accounting.

Coverage is explicit: Scheduler and shared AsyncWorker jobs in this process
and event loop. Standalone legacy pipes/timers that bypass these owners do not
appear. Completed workers are removed; there is no durable completed-job log.

## Session boundaries

Entry and every operation require an authenticated Master or Owner session,
matching existing scheduler-control roles. A changed session level is checked
on the next operation and can revoke command mode, using the partyline's
existing authenticated-session policy.
Mode, working directory, output and bounded history belong to that connection.
The existing partyline line rate limit still applies. The console never sends
its bare command lines to chat or executes a raw PID kill. Trusted usage errors
are typed separately from backend exceptions; raw backend detail is not echoed.
Successful actions receive a scoped operational log entry.

No schema, configuration or dependency change is required. After installation,
restart the development bot through the delivery procedure before using the
new module, registrations and scheduler timing fields.
