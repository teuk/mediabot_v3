# MB1124 — AsyncWorker child boundary

A callback exception is distinct from a normal return, even when the
exception object tests false. AsyncWorker now uses an explicit eval success
flag and sends the existing `worker_exception` result without evaluating
the exception's truth value. A successful return of zero remains valid.

The child branch always exits. If the internal worker entry point throws
or returns instead of terminating normally, the parent reports the existing
`worker_exit` failure. The child cannot return to the caller or run inherited
Perl destructors.

The existing worker contract test forks real children and covers both
exception objects, both abnormal entry point exits, and a normal zero return.
There are no changes to the transport protocol, settings or database.
