# MB1045 — Consistent Hailo nickname recognition

Reviewed snapshot: `snap_mediabot_v3_teuk_20261031_195709.zip`.
Base: `91686142236d8dd62fbcfe7e18724118e3cd2bf8` (MB1044),
VERSION `3.8dev-20261031_185103`.

Hailo already folds IRC punctuation when deduplicating nicknames and deriving
persistent bucket identities. Its matching expressions only ignored letter
case. Thus Te[u]K and Te{u}K shared a bucket but the second spelling could stay
raw in learned text. Deduplication made this worse when only one spelling was
retained. Output restoration and copied-line prefixes had the same mismatch.

A private shared nickname fragment now expands only the punctuation pairs
identified by the existing fold helper: brackets/braces, backslash/pipe and
caret/tilde. Every other character remains quoted. Mention substitution keeps
its original word boundaries and Unicode case matching. Prefix removal and
visible-name restoration reuse the fragment.

Twenty assertions call the real normalizer, rehydrator and bucket helper.
Fourteen fail on the original runtime. Cases cover peer/speaker/bot identities,
fold-equivalent deduplication, copied prefixes, leading bot addresses, incoming
command classification, output command rejection, Unicode/ASCII names, larger
word boundaries, escaped regex metacharacters, nick-switch placeholders,
stable bucket equivalences and warnings. No IRC/HTTP/SQL connection, worker,
listener or brain file is used or modified.

This aligns matching with the normalizer's existing fixed fold policy; it does
not add negotiated mapping support or change the upstream IRC trigger rules.
Persistent hashes, brain contents, nickname selection, length limits, command
prefix policy and activation/learning decisions are otherwise unchanged.

The operator flow requires the entire visible --progress suite and native
audits before restarting dev only. A new positive PID must stay active/stable
ten seconds before native interactive commit.sh performs automatic 3.8dev
commit/push. VERSION is not manually edited. Process stability does not prove
IRC reconnection. No production, schema, configuration, dependency, project
README/banner, radio or YouTube change.
