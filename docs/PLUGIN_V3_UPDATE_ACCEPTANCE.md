# API v3 production update acceptance

MB785 is the live acceptance of the updater-state boundary introduced by
MB772. MB786 records that evidence in source and adds an isolated executable
rehearsal. MB786 itself contacts no production service and changes no runtime
authority.

## Accepted production transition

The authenticated nbot operator used the local-only `update status` path
before one `update now` request on `#i/o`.

| Evidence | Accepted value |
| --- | --- |
| Previous source | `62820dc` / `3.6dev-20260924_144509` |
| Installed source | `7db72ea` / `3.6dev-20260924_204823` |
| Durable result | `success/completed` |
| Staged gates | Perl syntax and startup integrity before shutdown |
| Service contract | `Restart=always`, `ExitType=cgroup` |
| Stopped snapshot | after bot exit, before release rotation |
| Previous release | `/home/mediabot/mediabot_v3.229` |
| Acceptance marker | `MB785-NBOT-20260925T132057Z-354760` |

The updater completion notice was observed after the new process rejoined
`#i/o`. The temporary Partyline/IRC identity was then removed.

## Preserved instance state

The complete `plugins.DATA_DIR` tree was fingerprinted before and after the
rotation. Acceptance covered regular-file bytes, modes, ownership and stable
timestamps. The core-owned `.api-v3-runtime-state.json` boot ledger and the
retained Short Content KV revision were byte-for-byte identical.

After restart, these exact packages were operational, fully permitted,
enabled/on on `#i/o` and at zero failures:

- `quotes-v3`;
- `channel-activity-v3`;
- `factoids-v3`;
- `playful-v3` with `quiet_magic` disabled;
- `short-content-v3` with the retained MB783 repository revision.

Quote and factoid tables were unchanged. No package posture was reconstructed
or widened by the updater; previously committed operator intent alone was
restored.

## MB786 executable rehearsal

The MB786 regression creates two local Git revisions and runs the real
`install/deploy_update.sh` against a disposable instance. A minimal bot writes
one marker from its `SIGTERM` handler. The new release must contain that marker,
which proves that the plugin-data snapshot happened after the bot stopped.

The rehearsal also requires:

1. staged startup-integrity validation before shutdown;
2. the stopped snapshot before the two release moves;
3. the new version on the live path and the old version in one exact archive;
4. `success/completed` durable status with exact old, target and installed
   versions;
5. byte, mode, owner, group and timestamp preservation for the boot ledger and
   Short Content KV document;
6. no external network, systemd unit or production path.

This is a regression guard, not a second production pilot. A failure blocks
the source commit. It never attempts to repair or modify the accepted nbot
posture.

## Recovery boundary

The updater predicts one numeric archive before rotation. The live MB785 run
retained that exact old release as `mediabot_v3.229`. If post-activation
acceptance had failed, the operator wrapper would have stopped the exact
service, quarantined the failed candidate and restored only the predicted
archive after the updater had finished.

Package authority remains independently reversible through policy `off`,
disable and unload. Release rollback and package rollback are separate
decisions; neither is inferred from restart.
