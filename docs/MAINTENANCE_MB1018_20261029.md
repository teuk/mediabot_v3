# MB1018 — Honor explicit redirect limits in the shared HTTP factory

## Reproduced problem

`Mediabot::External::_make_http` accepted caller options but omitted
`max_redirect` when constructing `HTTP::Tiny`. Explicit zero and positive limits
were silently replaced by the HTTP library's default, currently five redirects
in the qualification runtime.

Several existing news/horoscope calls explicitly request `max_redirect => 0`.
With the real shared factory, a GET followed a redirect despite that request.
A budget of one followed two hops. A POST receiving 303 contacted a second
loopback origin, and the actual `_news_tavily` caller accepted a redirected
result instead of reporting the failed endpoint and retaining its fallback.

## Change

Forward `max_redirect` only when the caller supplies it, including numeric zero.
The underlying HTTP client retains ownership of the option's semantics. Calls
omitting the option retain the native default; no global redirect ban is added.

Only one runtime line changes, in `Mediabot/External.pm`. Timeout, agent, body
size, TLS verification, the reviewed explicit TLS compatibility opt-out and
default headers are preserved. Caller URLs, API configuration, provider
fallbacks, worker budgets and database schemas are unchanged. This does not
change the separate plugin HTTP service or its manual redirect validation.

## Regression and qualification

`t/cases/1393_mb1018_http_redirect_budget.t` adds eight focused assertions. Four
fail on the supplied unchanged snapshot; all eight pass after correction.
No existing test is modified, removed or excluded.

The fixture uses two actual TCP listeners bound only to `127.0.0.1` on ephemeral
ports. The shared factory, `HTTP::Tiny` request/redirect engine and real news
caller run unchanged. No external service, live configuration, IRC connection
or database is used. A bounded child serves deterministic responses; the parent
terminates and reaps its own fixture child. Request records contain only local
routes, methods, body lengths and the presence of an artificial authorization
header, never a credential value.

Coverage includes zero/one/two redirect limits, unchanged default behavior,
POST 303 across origins, POST 307 without replay, the real news fallback path,
preserved client options and actual response-byte-limit enforcement. This is
a controlled reproduction, not evidence of a live endpoint having redirected
or of a production credential having been disclosed.

Qualification commands:

```bash
perl t/test_commands.pl --filter '1393_mb1018|make_http|tls|horoscope|news|shorturl|tinyurl|module_structure' --progress
perl t/test_commands.pl --progress
perl tools/security_audit.pl --quiet
perl tools/startup_integrity_check.pl --quiet
perl tools/mb_architecture_inventory.pl --check docs/generated/COMMAND_INVENTORY.md
```

The delivery README records actual qualification results, including any failure
also reproduced on the unchanged source in this environment. The deployment
block stops at the first failure, restarts only dev after successful checks and
then invokes native `commit.sh` for versioning, confirmation, commit and push.
No live deployment or commit is performed by the offline qualification.
