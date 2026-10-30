# MB1026 — Public-checkout development-version tests

GitHub CI for `78e690df790c47e510cace03683e8ecd6d746f33` failed three assertions
in `1399_mb1025_development38_native_version.t`. The new test assumed the
maintainer's local `commit.sh` was available. That script is intentionally
ignored and not part of the public repository. Debian's fresh-install gate
passed; its success does not replace the complete offline CI gate.

The test now checks timestamped 3.8dev parsing and ordering after stable 3.7
using `Mediabot::Version::Format`, which is tracked and runs in every checkout.
The original three native `--version-plan` assertions remain conditional on
the local tool being installed. Only true absence skips them; a present tool
that is unreadable, malformed or returns incorrect results remains a failure.
The caller-directory assertion still runs in both cases.

No application module, CI workflow, local commit helper or VERSION file is
changed by this patch. On teuk, normal `commit.sh --skip-preflight` continues
the already-open 3.8dev line and produces its native timestamp. Do not reopen
3.7 or manually edit VERSION. Full-suite success remains required before the
operator invokes commit/push. No service restart is needed for this test-only
correction.
