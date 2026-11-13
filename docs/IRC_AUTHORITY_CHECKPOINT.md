# IRC authority checkpoint — MB1276

Source baseline: `454bef0573cc9e46790d1e92c2af6299cd6cd8db` (MB1275), matching
all tracked files in the maintainer's 2026-11-13 08:47:41 snapshot. Commit presence
is not proof of a particular full-suite transcript or of running-code activation.
This is a bounded review of row 4, not a new authentication policy.

## Expected contract and verdict

A decision must use the matching account's current permissions; revocation must
reach future decisions and owned deferred work. A server account, live IRC nick,
registered Mediabot account and matched hostmask are different identities.
Verdict: **partly covered**, with explicit policy and protocol limits below.
The reproduced cache/console defects selected in MB1271–MB1275 have committed
fixes. This checkpoint selects no further runtime change and moves the audit to
row 5; it does not certify universal connection-bound authentication.

| Situation | Owner and evidence | Verdict / boundary |
| --- | --- | --- |
| Same full prefix repeated | [Helpers::get_user_from_message](../Mediabot/Helpers.pm), five-second fullmask cache; new offline probe | Covered within the existing TTL. Cache age and direct external SQL mutations remain separate concerns. |
| Nick or host changes in the next message | Helpers opens a new candidate lookup; [User::Candidate](../Mediabot/User/Candidate.pm) evaluates configured masks and cloak rules | New prefix cannot directly reuse the old cached object. Unlisted host fails the probe. This is not a CHGHOST-event test. |
| Another prefix matches the same logged-in account | [User::Lookup](../Mediabot/User/Lookup.pm) selects USER.auth; [LoginCommands::_ensure_logged_in_state](../Mediabot/LoginCommands.pm) reconciles that account into a live session | Account-wide policy: another allowed mask can inherit auth=1 even without a separate password exchange. Broad masks therefore broaden authority. Per-connection authentication would be a deliberate policy migration, not a transparent bug fix. |
| Ordinary observed NICK then QUIT | [Auth::rename_session](../Mediabot/Auth.pm), main NICK handler, existing case 596 | Exact live spelling migrates the session and later logout finds it. Case-only changes are covered. |
| RFC-equivalent punctuation in Auth session keys | Auth uses Perl lc; probe registers Nick[ and attempts rename through Nick{ | Partly covered: Auth keys do not consume negotiated CASEMAPPING. The probe demonstrates a missed lookup, not an observed privilege escalation. No durable identity migration is introduced. |
| IRCv3 ACCOUNT / CHGHOST notification | [Main handler registration](../mediabot.pl); no dedicated handlers found at this baseline | No account-notify/chghost authority guarantee. RPL_WHOISACCOUNT routes to XAuth for bot network-service authentication; it is not participant login synchronization. Do not enable or advertise this as completed support. |
| Channel/global role mutation and explicit logout | UserCommands, Helpers, Auth; MB1271–MB1274, cases 72/75/591/163 | Selected stale cache and deleted-account session paths corrected. Failed SQL or an already captured User/Context is not a universal revocation boundary. |
| Partyline role change or deletion | [SessionAuth::refresh_account_authority](../Mediabot/Partyline/SessionAuth.pm), MB1275 fixture in case 75 | Changed/missing/unconfirmable authority retires console state, pending eval and watches. Unchanged privileged peers remain. This is triggered by native account mutations, not external SQL. |
| Deferred shell observation | [ShellWatch::_tick](../Mediabot/Partyline/ShellWatch.pm), case 1406 and MB1275 | Session/stream/task/state and role checked, including after rendering. Revocation reaches the retained session. Already transmitted bytes and started subprocesses are not recalled. |
| Script timer execution | [ScriptDryRun timer callback](../Mediabot/Plugin/ScriptDryRun.pm), [ScriptActionRunner](../Mediabot/ScriptActionRunner.pm), case 725 | Rechecks plugin enabled/apply state and passes current IRC/topic/kick/ban permissions to scoped action application; no recursive timer scheduling. Authority is configured plugin policy, not a promise to re-login the original human at timer expiry. |

## Reproduction and evidence boundaries

Run from the repository root:

```sh
perl -I. tools/dev/irc-authority-probe.pl
perl t/test_commands.pl --filter '^(591_|596_|725_|1406_|75_|163_)' --progress
```

The new probe calls native Helpers, Auth, User and LoginCommands using a small
candidate/role database fixture and synthetic public-style prefixes. It checks
cache separation, an unlisted host, the established account-wide auth policy and
Auth's exact nick-key behavior. It neither contacts SQL/IRC nor negotiates
capabilities or verifies a password. CHARACTERIZED POLICY/LIMIT assertions
intentionally document current behavior; passing them does not mean those limits
are repaired. Changing the policy later requires deliberately updating the probe.

Local validation: the new probe passes 14 assertions. Existing cases 591/596/725
pass 151 assertions with native IO::Async available (case 725 runs all 60 checks).
The wider six-case attempt encountered missing local dependencies in the other
three cases; it is not reported as successful. Installed-host acceptance of all
six remains mandatory in the package. Patch tooling passes nine tests, and an
isolated repository verifies apply/reverse, guards and actual commit.sh against
a local-only remote.

Existing case 725 has dependency-dependent integration coverage; its actual output
must be inspected rather than treating a skipped native loop as a pass. The package
requires the six-case lane on the installed host. No runtime module changes, full
suite rerun, service restart, configuration edit or schema migration is requested
by this documentation/tooling checkpoint. The new tool is not run at bot startup.

## Finite exit plan

Rows 1–4 now have bounded partial verdicts, selected corrections and explicit
residuals. Do not reopen them merely to implement optional Eggdrop features.
Row 5 is the remaining assessment: review existing reload/lifecycle evidence and
the MB1270 keepalive finding, reproduce any selected recovery blocker, then either
fix it or record an explicit bounded limitation. A reproduced blocker must not be
silently reclassified as optional. Roadmap closure still requires target-host
acceptance of selected runtime fixes; it never means complete Eggdrop parity.

No numeric deadline or fixed patch count is promised before that recovery review.
