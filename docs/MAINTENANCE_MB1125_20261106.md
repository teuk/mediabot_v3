# MB1125 — AsyncWorker termination and ownership

The deadline for forced completion and the TERM grace period can be set
independently. When forced completion ran first, it detached the KILL
timer and could leave a TERM-resistant child running after `on_done`.
The backstop now attempts KILL before finalizing. The process watcher
still owns reaping, and a child that has already been reaped is never
signalled.

Once termination starts, its cause and cancellation reason stay fixed:
a later timeout does not relabel a cancellation, and a later cancellation
cannot hide an established timeout. Forked code cannot cancel a worker
owned by its parent using an inherited handle.

The native termination tests exercise a TERM-resistant child, short
backstop grace, both event orderings and a real inherited handle. There
are no protocol, configuration or database changes.
