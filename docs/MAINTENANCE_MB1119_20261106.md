# MB1119 — Release Quotegame timers safely

The Quotegame countdown held a strong reference to itself through its
callback. Stopping a round could leave that cycle alive. An exception
while announcing expiry could also skip notifier cleanup. Rearming
the same round reused its token, allowing a retained expiry to end
the new timer's round early.

Quotegame now uses the shared single-use countdown. It releases the
notifier before announcing the answer, cancels on the timer's owning
loop, and checks a distinct identity for every arm. If the native
timer cannot start, the round remains available and its deadline is
still checked on the next channel message.

Native IO::Async tests cover cancellation, a late callback after
rearming, an output exception and a startup failure after partial
arming. The round's normal duration, text and scoring are unchanged.
No schema or configuration change.
