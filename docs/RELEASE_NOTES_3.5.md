# Mediabot 3.5 — The Castle Gates Open 🏰✨

Mediabot 3.5 is a consolidation release for long-running IRC communities. It
turns the extensive 3.4 development line into a reproducible stable source
release with stronger runtime boundaries, safer upgrades and a supported web
console.

## Highlights

- Per-channel Hailo brains with reply-before-learn ordering, bounded chatter
  policy and provider-neutral post-editing with deterministic fallback.
- Native Gemini support behind an independent, disabled-by-default channel
  capability.
- A supported, read-only-by-default mbweb console with durable MariaDB
  sessions, central CSRF protection, bounded authentication throttling,
  loopback binding and sandboxed systemd deployment.
- Hardened asynchronous workers, external HTTP boundaries, plugin/script
  execution and privileged command authorization.
- Reproducible release archives produced from an explicit Git ref, with both
  SHA-256 and SHA-512 manifests.

## Installation and upgrade proof

The accepted candidate passed the complete offline suite and the dedicated
Debian 13 workflow. That disposable workflow built the exact candidate archive
and exercised:

- fresh configuration as the non-root `mediabot` account;
- fresh MariaDB installation and strict schema drift checks;
- static systemd installation and verification;
- a representative stable 3.3 database upgrade;
- exact rollback to the pre-upgrade dump;
- deterministic reapplication to the same final database state.

## Security boundary

The cross-cutting audit covers 37 fail-closed invariants over 16 axes. Public
archives exclude private configuration, credentials, logs, runtime state,
dependency trees and local operator tools. The mbweb dependency lock is clean
at the `moderate` audit threshold.

## Operational boundary

Publishing 3.5 does not deploy or mutate a production instance. Database
reconciliation, channel pilots, instance rollout and observation remain
explicit operator-managed procedures with their own backup and rollback
decisions.

The candidate crossed the Debian trials, the portraits stopped arguing, and
the release scroll is ready for the owl. 🦉📜
