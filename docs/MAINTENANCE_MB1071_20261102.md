# MB1071 — Shared authentication mask compilation

## Defect

Auth still translated each star into an independent greedy .* expression,
even after the channel-ban matcher was corrected. A stored hostmask containing
25 repetitions of *a and a final b stalls on a host containing 70 letters a.
The native Auth regex probe required termination after three seconds.
hostmask_matches evaluates all stored patterns for each candidate while choosing
the most specific match, so a valid match later in the list cannot bypass this
delay. Autologin and other callers of that matcher can block with it.

## Implementation

Move the existing predictable glob compilation from ChannelBan into the small,
I/O-free Mediabot::IRC::Glob module. Both callers request a quoted fragment;
each retains its original anchors and /i flag. In particular, Auth still uses
a strict string end, while ChannelBan retains its historical line-end behavior.
The compiler supplies neither authentication decisions nor mask validation.

Consecutive stars collapse and each intermediate fixed piece commits at its
earliest occurrence, preventing later failure from retrying all earlier star
allocations. Literal escaping, ?, *, case behavior and empty-input behavior
remain caller-compatible. Do not add length/star-count limits or silently drop
stored masks. No cache, new dependency, runtime timeout or SQL change.

Auth's candidates, raw/legacy hostmask variants, specificity scores and stable
tie order are unchanged. Password verification, autologin flag/cloak policy,
session ownership and database updates retain their existing implementation.
ChannelBan selection and JOIN handling also remain unchanged.

## Validation and delivery

Keep fourteen assertions in 08_auth_module.t: group the three related
construction/API smoke checks into one and add two native scenarios. Retain
all password acceptance/rejection, no-DB and prior autologin checks.

The native scenarios use real Auth matching and a SQLite USER table with a
deterministic NOW function. Check the problematic non-match before a valid
more-specific mask, equal-score ordering, legacy tilde candidates, literals,
Unicode question-mark behavior and the distinct caller end anchors. Then
exercise real autologin: the matching account gains its expected database
flag and live-nick session; a nonmatching account remains untouched.
Five-second interruption guards belong to tests only and detect a regression
without turning it into a successful non-match. The application has no timeout.

Keep the seven native/wiring checks of 655 and the other ban/auth cases active.
Local before/after comparisons of generated short and encoding cases are not
installed into the test suite. No new test case. The existing module-structure
test adds one check for the new compiler; Auth's own assertion count is stable.

Preserve VERSION, private commit.sh, root README, full runner/ETA, radio, YouTube
and earlier fixes. The operator runs the full suite and audits before restarting
dev only and invoking the installed commit.sh with automatic 3.8dev VERSION.
See package QUALIFICATION.md for observed results and limits.
