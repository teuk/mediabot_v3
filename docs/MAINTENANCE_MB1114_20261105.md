# MB1114 — Let only the current database timer write to IRC

The SQL timer reload starts all new handles before publishing them, so
it can keep the previous set if a start fails. The callback previously
sent its IRC command without checking that publication. A callback
invoked during setup, after rollback, or from a retired handle could
therefore still send a command. A timer with the same name was enough
to make a name-only check ambiguous.

Each reload callback now holds weak references to the bot and its
specific timer. It sends through the existing IRC writer only if that
handle is still registered under its name. A failing reload leaves the
old timer authorized. A successful reload transfers that authority to
the new handle. Cleanup clears the registry before retiring handles.

The existing native IO::Async/SQLite test invokes actual timer events
during start and on retained handles after rollback, replacement and
cleanup. Only the published handles write. Intervals, the SQL query,
authentication and the existing IRC line checks are unchanged.
