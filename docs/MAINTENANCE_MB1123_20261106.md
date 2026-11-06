# MB1123 — Scheduler recovery after exceptions

The scheduler already isolated exceptions raised by task bodies. Its calendar
resolver and timer lifecycle used separate error handling that tested the
exception's truth value or converted it to a string. An exception object can
run code during either conversion and throw again, bypassing recovery. A
calendar task could then show as started in the Partyline with no next timer.

The scheduler now tracks resolver success independently of its result and
uses one bounded formatter for exception diagnostics. A failed calendar
re-arm stops only its own task. Failed periodic registration or partial start
still rolls back the original timer, and registration rethrows the original
exception after cleanup.

The existing native loop test covers a failing calendar re-arm, a partial
periodic start and a partial registration. It verifies cleanup, restart or
registration recovery, and that error handling never invokes object overloads.
