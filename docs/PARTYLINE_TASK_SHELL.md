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

## Commands

| Command | Behavior |
| --- | --- |
| `help` or `?` | Concise built-in guide |
| `pwd`, `cd [path]` | Navigate `/`, `/workers`, `/schedulers`; `..` and `.` work |
| `ls [path]` | Resource directories or tasks in the selected directory |
| `ps` / `jobs` | All tracked tasks; active workers first, longest durations first |
| `ps workers`, `ps schedulers`, `ps slow` | Filter by owner; slow means at least one second |
| `ps all 2` | Next listing page; at most twenty rows per page |
| `show <id>` / `cat <id>` | State, deadline/PID/progress count or scheduler timing/ticks |
| `kill <id>` / `stop <id>` | Request worker cancellation, or disable future scheduler ticks |
| `start <s-id>`, `restart <s-id>` | Use the scheduler's native lifecycle |
| `history`, `!!`, `!number` | Last twenty commands, with non-rebound numbered replay |
| `complete [prefix]` | Text suggestions for commands, directories and active IDs |
| `exit` | Return to ordinary partyline chat without disconnecting |

Quoted arguments and backslash escaping are supported. Read listings accept up
to two literal filters: `ps | grep -i "radio lookup" | head 5`. Pipes may be
adjacent to words. `grep` uses literal substring matching, with optional `-i`;
`head` accepts 1–50. Filters are validated before the listing or action starts;
mutating commands cannot be piped. No OS command, substitution, redirect or
general-purpose interpreter is invoked. This is a line-oriented shell; textual
`complete` supplies suggestions, without claiming a terminal TAB/arrow editor.

Existing dot commands remain usable, including `.quit`. `.command off` is an
additional way back to chat. Bare unknown commands in shell mode stay private
and produce help guidance instead of being broadcast as partyline chat.

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
