# Partyline architecture

This document describes the current `Mediabot::Partyline` module boundary on
the `3.4dev` line.

The design rule is simple:

> `Mediabot::Partyline` is the historical facade and small runtime core. New
> behaviour belongs to the module that owns the responsibility.

The split preserves the historical package surface used by existing callers
while making physical implementation ownership explicit.

## Module map

### `Mediabot::Partyline`

The parent owns only the Partyline core:

```text
new
get_port
_runtime_status_path
_runtime_status_payload
_write_runtime_status
```

Its responsibilities are object construction, configured port access and
runtime-status publication. It also imports the historical method surface from
the focused modules below.

No physical `_cmd_*` implementation belongs in the parent.

### `Mediabot::Partyline::Transport`

Owns the transport boundary:

```text
TCP listener
DCC CHAT listener/offers
IO::Async stream handling
input framing and line limits
socket/transport errors
transport-side session bootstrap
```

Transport-specific dependencies belong here rather than being kept in the
parent merely because the code was once monolithic.

### `Mediabot::Partyline::SessionAuth`

Owns session lifecycle and authentication:

```text
login/password flow
session state
timeouts
authentication throttling
reverse DNS/session metadata
session/broadcast helpers
```

### `Mediabot::Partyline::Dispatcher`

Owns the line dispatcher and command routing.

The dispatcher continues to call the historical `Mediabot::Partyline` method
surface. It does not need to know which physical module implements a command.

### `Mediabot::Partyline::Commands`

Owns ordinary Partyline commands, including operator controls, diagnostics,
IRC lifecycle controls, moderation, scheduler/reload commands, network
visibility, reminders, karma and anti-flood controls.

This module is the normal destination for a new Partyline command when the
command does not require a stronger boundary of its own.

### `Mediabot::Partyline::Privileged`

Owns:

```text
_cmd_eval
_cmd_die
```

These commands have a different security/process risk profile from ordinary
operator commands. Keeping them in a separate module makes that privileged
boundary explicit.

## Compatibility rule

Physical source location is not part of the public API.

For example, a caller may continue to use:

```perl
Mediabot::Partyline->can('_cmd_status')
```

even though the implementation lives in `Mediabot::Partyline::Commands`.

Tests should therefore distinguish:

```text
historical/public method availability
```

from:

```text
physical implementation ownership
```

Source-structure tests may verify ownership, but product code should not depend
on a command being physically defined in the parent file.

## Boundary regression

The final MB678 architecture is locked by:

```text
t/cases/881_mb678_partyline_boundary_closure.t
```

That contract protects the small parent/core boundary and the ownership of
imported Partyline methods.

## Validation after Partyline changes

Use targeted contracts first, then the reviewed fast lane, runtime smoke and
the full suite:

```bash
perl t/test_commands.pl -f '^(88[01]_)'
perl t/test_commands.pl --fast --progress
perl t/test_commands.pl --progress
```

For runtime validation, inspect the application log first:

```text
/home/mediabot/mediabot_v3/mediabot.log
```

and use the systemd journal as a complementary service/process view.
