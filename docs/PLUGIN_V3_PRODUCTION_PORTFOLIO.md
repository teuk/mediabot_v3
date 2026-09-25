# API v3 production portfolio

MB784 consolidates the production evidence accepted through MB783. It changes
source contracts and operator documentation only: production is not contacted,
no package is loaded or reconfigured, and the development boot ledger must
remain byte-for-byte unchanged.

## Accepted sequence

The production sequence stayed observe-first and reversible throughout:

1. **MB773** reconstructed the updater-lost `quotes-v3` and
   `channel-activity-v3` postures as enabled/observe, proved bounded activity
   reads, and verified exact restart restoration.
2. **MB774** promoted `quotes-v3` to enabled/on with one disposable
   add/view/delete proof and complete cleanup.
3. **MB775** promoted `channel-activity-v3` to enabled/on with singular
   `compare` and five-line `heatmap` evidence.
4. **MB776** retained `factoids-v3` in enabled/observe after identical
   missing-key output in observe and a bounded on window.
5. **MB777** promoted `factoids-v3` to enabled/on with one disposable
   learn/recall/forget proof and complete cleanup.
6. **MB779** retained `playful-v3` in enabled/observe after identical
   `abbrev` and `morse` output, with `quiet_magic` disabled.
7. **MB780** promoted `playful-v3` to enabled/on while keeping the autonomous
   job dormant.
8. **MB782** retained `short-content-v3` in enabled/observe after a silent,
   repository-write-free request and one bounded on request whose repository
   revision was restored.
9. **MB783** promoted `short-content-v3` to enabled/on after another silent
   observe request and one authoritative HTTPS read that retained exactly one
   bounded repository revision.

Every gate checked the already accepted ledger entries byte-for-byte before
and after the change. Every final posture survived a production service restart
with complete permissions and zero plugin failures.

## Accepted final posture

All five packages are persistent, enabled and `on` only for production
`#i/o`:

| Package | Granted authority | Runtime surface | Retained evidence |
| --- | --- | --- | --- |
| `quotes-v3` | quote read/write, reply, notice | five commands | disposable add/view/delete cleaned up |
| `channel-activity-v3` | activity read, reply, notice | two commands | singular compare and bounded heatmap |
| `factoids-v3` | factoid read/write, reply, notice | five commands | disposable learn/recall/forget cleaned up |
| `playful-v3` | channel message, reply, notice, scheduler | six commands, one dormant job | abbrev/morse parity; `quiet_magic` disabled |
| `short-content-v3` | HTTPS fetch, reply, namespaced KV | one command | exact `MB783-mediabot_v3`; one bounded repository revision |

The portfolio has zero recorded plugin failures. Quote and factoid rows were
unchanged after cleanup, no source file changed during production acceptance,
and only the verified short-content repository revision remains.

Installation still grants no authority. Every manifest remains default-off;
the core-owned boot ledger records the explicit operator decision, and MB772
preserves that ledger and bounded plugin state across release rotation.

## Health and restart gate

For each package, an authenticated Owner checks:

```text
.plugins doctor <package>
.plugins permissions <package>
.plugins why <package> #i/o
.plugins failures <package>
```

Acceptance requires `ready`, complete permissions, one active `on` policy,
zero failures and the expected command/job counts. After restart, Mediabot
must rejoin `#i/o` before the same checks are repeated.

## Immediate rollback

Rollback is package-scoped and does not depend on restart:

```text
.plugins policy <package> #i/o off
.plugins disable <package>
.plugins unload <package>
```

`off` stops new authority and restores a saved historical handler where one
exists. Disable stops the package while retaining its configuration. Unload
removes the runtime entry and the next-boot ledger entry. For
`short-content-v3`, repository cleanup is a separate explicit Owner action and
must use the namespaced `clearv3data` command only when data removal is
intended.

## MB784 consolidation boundary

MB784 records the accepted MB782 and MB783 evidence in the machine contract,
documentation and executable tests. It does not contact nbot, change the five
production policies, mutate the development ledger, add a capability, or
replay a live probe. The next authority decision therefore remains separate
and must begin with its own bounded observe gate.

## MB785 release-rotation acceptance

MB785 tested the MB772 preservation repair against the complete portfolio.
One authenticated `update now` request moved nbot from exact MB781 source
`62820dc` to reviewed MB784 source `7db72ea`. Staged syntax and startup
integrity completed before shutdown; durable status finished
`success/completed`; systemd restarted the instance; and the exact old release
remained available as `/home/mediabot/mediabot_v3.229`.

The post-update gate repeated doctor, permissions, why and failures for all
five packages. Every package returned enabled/on on `#i/o` with complete
permissions and zero failures. The complete plugin-data tree, core boot ledger
and retained Short Content KV revision were exact. Quote and factoid rows did
not change, and the disposable operator identity was removed.

MB786 records that acceptance in the machine contract and an isolated updater
rehearsal. It replays no production action, changes no development ledger and
grants no runtime authority. The detailed update evidence lives in
[`PLUGIN_V3_UPDATE_ACCEPTANCE.md`](PLUGIN_V3_UPDATE_ACCEPTANCE.md).
