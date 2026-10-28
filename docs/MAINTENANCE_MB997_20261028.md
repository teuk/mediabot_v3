# MB997 — Mask service credentials after leading whitespace

Base: `snap_mediabot_v3_teuk_20261028_174301.zip`, VERSION
`3.6dev-20261028_164246`. All previous corrections remain present.

## Reproduced defect

The shared outgoing-private-message log redactor required the authentication
verb at character zero. Leading whitespace therefore bypassed credential
masking in PRIVMSG, ACTION and NOTICE diagnostics, including NOTICE debug
logs. This is a reproduced logging defect; no live credential exposure or
successful authentication by a remote IRC service is asserted.

The redactor now recognizes leading whitespace, then trims it on the log
copy only before splitting command fields. Unicode string semantics are
enabled lexically inside this helper, so whitespace such as nonbreaking
spaces is treated consistently during detection and tokenization.
Other routines in the module are unaffected.

Supported verbs, field positions and the existing masking marker are
unchanged. Caller scalars and actual outgoing data are not rewritten.
Ordinary private text, near-keyword words and whitespace-only strings keep
their exact content. Transport routing, encoding, splitting, channel logging,
configuration and dependencies are unchanged. No SQL or production rollout
change is included.

Technical reference for the scoped Unicode semantics:
[Perl Unicode support](https://perldoc.perl.org/perlunicode).

## Verification

Seventeen assertions exercise the actual redaction helper, its legacy
facade, and the real IRC::Output -> Helpers -> Sender paths with fixture
logger/IRC endpoints. Cases cover all supported verbs, spaces/tabs, Unicode
whitespace, keyword boundaries, caller immutability and ordinary messages.

Actual long PRIVMSG/ACTION/NOTICE sends put a fixture token in a later wire
chunk. Every normal/debug log must mask it, while emitted chunks reconstruct
the unchanged original message, preserve envelopes and remain byte-bounded.
Twelve assertions fail on the original runtime; all seventeen pass after
correction. No network, real credentials or IRC service is used by this test.

The delivery README records targeted/full suite results, security audit,
startup integrity and command-inventory verification. No test is excluded.
The user procedure runs the complete suite with --progress and stops on
failure before dev restart and native commit/push.
