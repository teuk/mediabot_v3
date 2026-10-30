# MB1027 — Separate LUSERS samples before parsing their counters

Source: `snap_mediabot_v3_teuk_20261030_171815.zip`, matching public master
`75f069b9e1e10cdf51e8d37edc30f040723cf564`, already in 3.8dev.

The network-statistics exporter used to parse a 251 visibility reply before
recognizing the new LUSERS cycle. If parsing returned no counters, the previous
pending sample survived. A valid following 266 total could therefore be merged
with the previous visible/invisible/operator/local counts. In the reproduced
case, the new total was 50 but the JSON snapshot still announced 100 users and
retained counters from the earlier burst. An old expired pending sample could
also cause the new valid total-only reply to be discarded.

A 251 now starts a fresh pending sample before counter parsing. Its arrival
sets the settling clock even if the breakdown is unavailable, so an unfinished
empty cycle is discarded normally. Following optional replies belong to the
new sample, and a 266 total remains usable without inventing a visibility split.
The last confirmed file is preserved when the new cycle never completes.

Seven offline regression assertions cover the actual core numeric dispatcher,
JSON publication, consecutive bursts, an expired predecessor, explicit zeros,
unparseable/restricted starts, incomplete cycles, valid structured starts,
settling, one-time publication, disconnect reset, default-off collection and
warnings. Four fail against the original exporter. No live IRC or database
connection is used by these fixtures.

Only NetworkStats.pm, its new regression file, this note and CHANGELOG change.
Existing schemas, dashboard fields, private configuration, polling intervals,
metrics cache behavior, radio, YouTube, plugins and published 3.7 assets are
preserved. Full-suite success and audits precede the fixed dev-only restart;
normal native commit.sh mode continues the existing 3.8dev timestamp format.
