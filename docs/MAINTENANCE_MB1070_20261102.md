# MB1070 — Predictable channel-ban matching

## Defect

ChannelBan translated every star into an independent greedy .* expression.
A mask containing twenty-five repetitions of *a followed by b could stall
matching a seventy-character run of a. This is a valid stored mask, not a
regex syntax error. eval cannot stop CPU-intensive backtracking. A three-second
external probe had to terminate the original matcher before completion.

active_ban_for_mask evaluates stored masks from newest to oldest on JOIN, so
one such non-match can prevent checking later bans and block the IRC callback.

## Implementation

Split on consecutive stars, retain quoted fixed pieces and question-mark dots,
and commit each interior star/fixed-piece match atomically at its earliest
position. Only the final star is allowed to search for its required suffix.
Later failure cannot retry all allocations of earlier stars.

Keep the existing /i modifier, anchors, quoting and error-return policy. Do not
add a mask-length/star-count rejection policy, drop bans or change case mapping.
The SQL selection, channel/active filters, latest-match ordering and stored bans
are unchanged. JOIN still matches the real nick!ident@host and sets the existing
normalized MODE mask. No changes to the IRC JOIN handler or Fullop policy.

## Validation

The existing 655 case keeps seven assertions. Replace the mirrored regex with
the real ChannelBan matcher. Exercise nickname bans, raw/normalized subject
differences, user/host patterns, literal regex punctuation, ?, consecutive stars,
case/Unicode folding, anchors, empty and undefined inputs.

Use a real SQLite CHANNEL_BAN table to retain channel/active/latest precedence,
skip the adversarial newer non-match, and confirm all rows remain intact.
The separate hard non-match must finish without interruption, and its positive
variant must still match. Five-second alarms prevent a regressed test hanging;
they are test-only, not an application timeout or microsecond benchmark.

The original four JOIN wiring checks are retained in one source guard, since
loading mediabot.pl would start the bot. The test does not claim to execute a
live JOIN. No new test file or increase in full-suite assertion count.

During local qualification, compare the actual baseline and corrected matchers
on generated short cases and byte/character flag variants. This comparison is
not installed or added to the server's test suite. See package qualification for
the observed results and limits.

No database schema, configuration, dependency or manual VERSION change. Keep
previous fixes, root README, private commit.sh, full runner/ETA, radio and YouTube.
The modop runs the full suite and audits before restarting dev only and invoking
the installed commit.sh with automatic 3.8dev VERSION after success.
