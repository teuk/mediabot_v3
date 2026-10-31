# MB1041 — External-script signal termination is a failed execution

Reviewed snapshot: `snap_mediabot_v3_teuk_20261031_151302.zip`.
Base: `95b67d0a30a7cadf3b45eac1f13537d92042d4a0` (MB1040),
VERSION `3.8dev-20261031_141031`.

ScriptRunner extracted an exit code from the high byte of wait status even
when the low bits reported termination by a signal. The high byte is zero in
that case. If the child flushed valid JSON before dying, the result combined
ok=1, exit_code=0 and a nonzero signal. The existing ScriptActionRunner trusted
the successful wrapper and could apply reply, log and storage actions.

The runner now reads the signal first and reports no normal exit code when
that signal is nonzero. Its existing success check therefore rejects the
execution. A bounded numeric error identifies the terminating signal. Captured
stdout/stderr and the parsed JSON response are retained for inspection; the
existing action layer refuses to plan or apply that failed result.

Normal exit zero, ordinary nonzero exits, malformed protocol responses and
runner-enforced timeout keep their previous behavior. No new kill operation,
signal handler, process-control policy, protocol version or dependency is added.
The existing timeout mechanism and permission gates are unchanged.

Eighteen assertions run actual Perl subprocesses through open3 and the normal
script path/payload/response machinery. TERM, INT and KILL fixtures flush a valid
reply/log/storage response and terminate only themselves. One fixture closes its
output descriptors first. The real action runner is exercised in dry and apply
modes with in-memory IRC, log and storage sinks; failed scripts must reach none
of those sinks. A clean successful child proves valid actions still apply.
Nonzero exit, malformed JSON and a real one-second timeout are also covered.
Nine assertions fail before correction; all eighteen pass afterward.
No external network, SQL server or service listener is used by these cases.

The delivery requires the full --progress suite and audits before a dev-only
restart and native automatic 3.8dev commit/push. VERSION is not edited manually.
No production SQL/schema, configuration, radio or YouTube change.
