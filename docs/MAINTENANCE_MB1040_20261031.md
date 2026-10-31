# MB1040 — HTTP body size and serialized worker size

Reviewed snapshot: `snap_mediabot_v3_teuk_20261031_145041.zip`.
Base: `d5741535b359ea5fa39d3895887af8f114184366` (MB1039),
VERSION `3.8dev-20261031_135031`.

The plugin HTTP service checked a raw UTF-8 response against max_bytes, then
passed it to AsyncWorker inside a JSON result record. Its max_bytes + 8192 pipe
budget did not cover JSON escaping. For example, a valid JSON array of 10,000
empty strings occupies 30,001 HTTP bytes, but its escaped representation exceeds
the default 40 KiB worker budget. Plugins received worker_output_limit instead
of the successful response. Such failures also contributed to the HTTP circuit.

The service now reserves six serialized bytes per permitted body byte, plus
16 KiB for the bounded URL, content type and worker envelope. A JSON control
escape such as \u0000 costs six bytes; valid UTF-8 text is no worse per input
byte. The transport allowance is finite: 208 KiB at the default 32 KiB body cap,
400 KiB at the maximum 64 KiB body cap. AsyncWorker itself is unchanged.

The original max_bytes is still passed to the HTTP requester and checked before
decoding. Strict UTF-8 decoding still runs before result serialization. This
change permits previously valid responses; it does not admit larger HTTP bodies
or malformed UTF-8, truncate responses or introduce retry/cache policy changes.

Sixteen assertions use the production AsyncWorker with real fork, JSON framing,
pipe, event loop and completion cleanup. Only DNS and the HTTP endpoint are local
fixtures; no network, database, listener or injected worker is used. Seven
assertions fail on the unchanged source and all sixteen pass after correction.
They cover complete JSON parsing, positive and zero-TTL cache paths, worst-case
escaping at 64 KiB, mixed Unicode/escape text, HTTP 503 bodies, plain maximum
bodies, default/small oversize rejection, malformed UTF-8, recovery and no active
worker or occupied HTTP slot after completion.

The delivery runs the full --progress suite and audits before a dev-only restart
and native automatic 3.8dev commit/push. VERSION is not edited manually.
No production SQL/schema, configuration, dependency, radio or YouTube change.
