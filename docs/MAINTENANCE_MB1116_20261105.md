# MB1116 — Keep deferred AntiFlood output on its original connection

Reconnect installs a fresh IRC object on the same bot and event loop.
A blocked PRIVMSG or ACTION previously stayed in its old AntiFlood
queue, so a pending countdown could send it on the replacement
connection. Messages submitted to that target after the reconnect
could also share the old drain schedule.

Replacing the IRC object now drops its deferred queue registry. Each
countdown checks that the exact queue that armed it still owns the
target. An obsolete callback leaves the replacement queue alone.
Head reinsertion and rearming remain specific to the draining queue,
including if a connection change occurs during an output callback.

The existing sender fixture exercises mixed PRIVMSG/ACTION deferral
through the real IRC setter and output queue. It checks replacement
of an armed queue, FIFO during a connection change in a drain, and
preservation when the same transport is assigned again. No database,
configuration or dependency change.
