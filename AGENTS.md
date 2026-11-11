# Working on mediabot_v3

## Source and scope

- For structural work, read `docs/ARCHITECTURE_ROADMAP.md` first, follow its
  incremental sequence and update progress with the delivered change. Distinguish
  local implementation from successful target-host acceptance.

- Start from the current GitHub development branch and record its full commit SHA.
  Use an explicitly supplied newer snapshot for local changes absent from GitHub;
  never silently combine different source revisions.
- Keep a change focused on a reproduced bug or an explicitly requested improvement.
  Read the owning modules and related tests before editing.
- Do not change the database schema, restart services, connect to production IRC,
  or modify runtime configuration unless the task explicitly requires it.
- Preserve the README header. Treat radio playback and YouTube preview behavior
  as regression-sensitive; changes there need coverage of existing behavior.
- Never include private configuration, credentials, logs, user data or local
  deployment files in patches, commits or issues.

## Validation

- Prefer extending relevant existing cases to adding one test file per patch.
- Use `perl t/test_commands.pl --filter '...' --progress` for targeted tests.
  Historical closure-style cases are not all compatible with direct `prove`.
- Run the fast lane for intermediate wider Perl checks when relevant. Run the
  complete suite once before the final commit of a runtime change, with visible
  `--progress`. Do not repeat it without a new change or failure to investigate.
- For tooling-only changes, run the tooling's tests. Follow any requested final
  host acceptance lane. Do not imply that a missing dependency is a passing test.
- Report what ran, what failed, and what remains to validate on the target host.

## Delivery and Git

- Deliver standard Git patches with the exact base commit, patch SHA-256,
  affected-file summary, validation commands and a focused English explanation.
- See `docs/PATCH_WORKFLOW.md` for isolated checkouts, patch creation and checks.
- Refuse dirty/staged work, unexpected base commits and interrupted Git operations;
  do not reset, force-apply or auto-resolve user changes.
- For the maintainer's host workflow, use its existing `commit.sh --skip-preflight
  -m "..."` after validation. `commit.sh` owns VERSION and push. It is intentionally
  ignored by Git and is not available from a fresh clone.
- Public commit messages are English, with a precise Harry Potter-inspired phrase
  and a suitable emoji. Do not claim a remote commit/push until verified.
- A GitHub draft branch/PR can support review when authorized, but does not replace
  host validation or the maintainer's required commit.sh flow. Never force-push.
