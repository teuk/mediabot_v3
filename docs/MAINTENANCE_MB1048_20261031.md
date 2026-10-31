# MB1048 — Current conversation ownership across MetaAI stages

Snapshot: `snap_mediabot_v3_teuk_20261031_215900.zip`.
Exact public base: `631f78df7d73356ac627dd5f7e6d311d03e46bf5` (MB1047).
VERSION: `3.8dev-20261031_205810`.

MetaAI already checked its configuration, channel policy, runtime generation
and memory ticket before publishing output. However, contributors could still
start search, synthesis or citation repair after those checks had become
invalid. Forget also left the old channel job locked until final completion.
Simply deleting that lock would allow an old completion to unlock a newer job.

MetaChat now accepts an optional caller-owned is_current predicate. Its stage
guard checks before dispatching or accepting contributor, search, native-web,
synthesis and repair work. A false or failed predicate completes the chain once
with a bounded cancelled result. Direct callers without the optional predicate
retain their existing behavior. No predicate enters a provider request.

MetaRuntime supplies its existing validity checks plus a distinct shared-job
reference owner. Successful forget releases only that shared room job, after
all existing memory stores have been processed. Late result, short-URL
presentation and pacing callbacks release a slot only if they still own it.
Other channel jobs and protected local results retain their separate behavior.
Normal evidence validation, citation repair, native-web fallback and current
deliveries retain their existing paths. Only fully delivered current output
enters shared memory.

Requests already launched retain AI::Client's normal worker deadlines/cleanup.
This prevents later stages; it does not forcibly terminate an HTTP request,
refund usage/rate budgets or promise cancellation of provider charges. Already
sent IRC lines cannot be retracted. Models, provider routing, source policy,
short-URL validation, pacing, persistence format and public commands are unchanged.

The new native case has twenty-eight assertions: eighteen fail on the untouched
runtime. It uses real MetaRuntime/MetaChat, activation policy and private memory
files, with delayed local client/search/presentation/scheduler boundaries and
an in-memory SQLite activation fixture. No paid API, external HTTP/IRC/MariaDB
connection or worker fork is made by this case. It covers immediate replacement,
configuration/policy/generation revocation, success/failure at research, evidence
repair, native web, source presentation, partial output, room isolation and
false/throwing predicates. Existing tests remain enabled. The old-generation
fixture no longer fabricates a synthesis that should never be launched; one
new no-dispatch assertion replaces that setup call, retaining every old assertion.

The operator script requires the full visible --progress suite and native
audits before restarting dev only. A new positive PID must remain active/stable
ten seconds before interactive commit.sh calculates the native 3.8dev VERSION
and performs commit/push. VERSION is not manually edited. Process stability is
not proof of IRC reconnection. No production, schema/configuration, project
README/banner, dependency, radio or YouTube change.
