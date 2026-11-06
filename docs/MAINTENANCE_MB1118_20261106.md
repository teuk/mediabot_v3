# MB1118 — Keep paced PRIVMSG replies on their original IRC connection

Paced PRIVMSG replies send an initial chunk, then keep the remaining
chunks and successor replies in a per-target queue. Replacing the IRC
object previously left that queue active. An old countdown could send
pending chunks on the new connection and delay its own replies.

The IRC setter now retires the paced PRIVMSG registry alongside the
AntiFlood and NOTICE queues. Before a pump uses its send guard, after
that guard, and after a send, it checks that its own queue still owns
the target. A retired pump releases its old payload and callbacks
without modifying a replacement queue. Assigning the same connection
keeps the existing pacing and ordering.

The regression test uses the production sender, IRC setter, and native
IO::Async timers. It covers an old expiry, a replacement in the send
guard and a replacement during a send. No schema, configuration or
dependency change.
