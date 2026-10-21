# MB870 — usable AI replies and fallback deadlines

Base: `snap_mediabot_v3_teuk_20261021_050702.zip`, after MB869,
`3.6dev-20261021_030645`.

## Reject malformed response fields

The Anthropic text adapter previously joined reference-valued text fields into
strings such as `ARRAY(0x...)`. The OpenAI chat adapter returned a container as
its answer directly. The common client accepted both as successful responses.
Whitespace-only responses were also accepted, preventing an authorized auto
fallback from reaching a usable provider.

Adapters now accept plain scalar text in these fields. The common client also
requires a scalar containing at least one non-whitespace character. Invalid
successful responses become `parse_error`, as other unparsable responses do.
Valid blocks around malformed blocks remain available. A scalar `0` remains
a valid nonblank answer. Existing OpenAI Responses text extraction is retained.

OpenAI error diagnostics and citation titles no longer stringify objects or
arrays. A citation with a malformed title keeps its admitted URL and an empty
title. Existing scalar diagnostic cleanup and length limits are preserved.

Explicit providers remain strict: this change does not send their content to
another company. An `auto` request can use its existing authorized fallback
order after an invalid response, instead of returning malformed output.

## Cover the sequential fallback plan

`submit()` previously gave the shared worker the longest planned HTTP timeout
plus three seconds. `_run_plan()` executes eligible attempts sequentially, so
a slow first provider or primary model could consume the watchdog before its
fallback had used its own permitted timeout.

The watchdog now covers the sum of the validated attempt budgets, plus the
same three-second margin. The plan's existing decisions still determine which
attempts actually run; unused budgets do not cause additional calls or waits.

| Example plan | Old worker watchdog | Corrected watchdog |
| --- | ---: | ---: |
| One 30-second Anthropic attempt | 33 s | 33 s |
| OpenAI primary and fallback, 20 seconds each | 23 s | 43 s |
| Auto: Anthropic 30 s, two OpenAI models 20 s each, Gemini 30 s | 33 s | 103 s |

Gemini's internal transient retry already shares one attempt deadline and is
counted once. The largest validated request budget in the current four-attempt
plan is 1,203 seconds (four times the 300-second request limit, plus margin),
below AsyncWorker's existing cap. No individual HTTP timeout is increased.

This can keep an eligible fallback worker alive longer during provider trouble.
Success still returns immediately; strict routing, model eligibility, quota
exceptions, TLS verification, output size and termination grace are unchanged.

## Offline regression coverage

- `1284_mb870_ai_response_scalar_contract.t`: direct adapter parsing, malformed
  fields, valid mixed text, citation/diagnostic cleanup, explicit-provider
  rejection, auto recovery and the common client boundary.
- `1285_mb870_ai_worker_fallback_budget.t`: actual submit watchdog arguments
  across explicit/auto/reordered/unconfigured/maximum-timeout plans, Gemini's
  shared retry budget, complete async provider/model fallback, quota behavior
  and exactly-once terminal delivery.

The tests exercise real plans, adapters and shared HTTP response handling with
local HTTP fixtures. Budget assertions do not sleep or depend on machine speed.
No remote API, live IRC connection or production database is needed by these
new tests. No schema, migration, private configuration or service change.

Executed results and environment limitations are in the package's
`QUALIFICATION.md`.
