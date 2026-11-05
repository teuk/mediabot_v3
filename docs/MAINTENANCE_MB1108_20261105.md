# MB1108 — Liquidsoap response deadline

The Liquidsoap client used the process-wide alarm to interrupt a blocked
read. It replaced an existing timer and cleared it on both the success
and error paths. Fractional read timeouts below one second also armed
no alarm at all.

The client now waits for socket readability with a monotonic deadline for
the whole response. It passes the remaining budget to each wait, including
after an interrupted syscall. Receiving a partial reply does not buy more
time. The caller keeps control of its own alarm. The connect timeout,
command and quit payload, SIGPIPE guard, 64 KiB response cap, first END
frame and request-ID check are retained. This does not make the client
asynchronous or change the write timeout.

The existing loopback probe now checks that successful commands leave a
pending caller alarm intact. A separate peer sends pieces of an unfinished
response past a subsecond budget; the client must report a read timeout
and the caller's alarm handler must still run. Both behaviors fail with
the original client. Existing checks for command injection, a reset peer,
normal acknowledgements and queue errors are retained.

No database, configuration or dependency change. The radio command
handlers, including playRadio, are unchanged.
