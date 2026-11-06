# MB1117 — Drop paced private notices when the IRC connection changes

The shared NOTICE queue schedules each line, including private help
pages, against the current event loop. A reconnect can replace the IRC
object on that same loop. Previously, already scheduled callbacks could
send to the same nick on the new connection. Old slots could also delay
new notices.

When the IRC object changes, the setter now retires the NOTICE queue
along with the existing AntiFlood queues. Callbacks still clean up the
slots they own at expiration, but can send only if their registry is
still current. Failed timer setup retains the immediate fallback for
the same connection. A connection replacement during setup suppresses
that fallback and the remaining arms.

The fixture exercises the real IRC setter and NOTICE queue with a
deterministic event loop. It verifies that new notices have a fresh
schedule, old callbacks are silent, assigning the same connection
preserves delivery, and a failed arm cannot cross the boundary.
