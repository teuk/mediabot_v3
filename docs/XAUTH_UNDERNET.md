# Undernet X authentication and recovery (MB838)

Mediabot uses one connection-bound controller for startup, `xauth`/`xlogin`
and periodic account verification on **network type 1** (Undernet-compatible).
Other network types do not send these service credentials. The existing
Libera/NickServ flow is retained. No database schema or migration is involved.

## Configuration

Keep credentials in the instance's private configuration, using the existing
keys. Do not supply them in an IRC command or paste them into diagnostics.

```ini
[connection]
CONN_NETWORK_TYPE=1
CONN_USERMODE=+iwx

[undernet]
UNET_CSERVICE_LOGIN=x@channels.undernet.org
UNET_CSERVICE_USERNAME=YOUR_X_ACCOUNT
UNET_CSERVICE_PASSWORD=YOUR_X_PASSWORD
UNET_CSERVICE_CHECK_INTERVAL=300
```

Preserve the instance's other modes and settings. A positive `x` requests host
hiding; `+iw` does not, and `+i-x` does not. Account authentication still runs
when valid service credentials are configured without +x. A compatible private
network may use its own server-qualified service address; bare `X`, channel
names, whitespace and injected commands are refused as credential targets.

The interval defaults to **300 seconds** when the key is absent. Positive
values clamp to 60..3600 seconds; zero disables periodic checks while retaining
connect/manual checks and completion of a pending login. Existing valid
configurations need no new setting to get the default five-minute checks.

Stop the exact instance before private configuration edits, keep a private
backup, and use `Mediabot::Conf`'s native writer and re-read checks. Restart the
instance to load updated source. Source installation never edits its private
configuration.

## Protocol and state

1. On a real IRC login, request WHOIS for the **actual connected nickname**.
   The configured preferred nick is not assumed to have been obtained.
2. Accept a complete matching server reply: numeric 311, optional account
   numeric 330, then 318. Replies must name the current bot, belong to the
   current transport and use consistent server prefixes. User-prefixed,
   unrelated, malformed, contradictory or incomplete evidence cannot grant
   authentication. A hidden hostname alone is not account proof.
3. If the complete reply has no account, send one `LOGIN` using the configured
   server-qualified service/account/password. Verify again after five seconds.
   Queueing LOGIN is not treated as successful authentication. A different
   account is reported as `account_mismatch`, without attempting to log out or
   switch it automatically.
4. When the configured account is confirmed, query user modes. If +x is
   requested and absent, request `MODE <actual-nick> +x`, then query again.
   Numeric **221** confirms the resulting modes. A failed or missing mode
   confirmation is visible and does not release deferred autojoins.
5. Release configured Undernet autojoins, including console, after account and
   any requested +x are confirmed. The normal `joinChannels` pacing remains in
   use. Periodic healthy checks and recovery do not repeat those initial joins.

Localized X NOTICE text is not parsed as proof of authentication. This avoids
language-dependent success matching and nick-only trust. The existing general
WHOIS/Partyline consumers retain their data; this controller never overwrites
`WHOIS_VARS`. A 311 owned by its self-probe retains Partyline visibility but
does not dispatch legacy user-authentication/ban callbacks from that shared
slot. Other WHOIS replies keep their normal callbacks. Routine account checks
therefore cannot replay a stale Mediabot user-session or SQL auth mutation.

The installed Protocol::IRC mapping exposes account numeric 330 by its named
callback, while numeric 221 is explicitly bound by number. Regression tests
feed real parsed IRC messages through Net::Async::IRC and the actual executable
callbacks to cover this distinction.

When configured Undernet authentication is required, initial channels wait for
it. Requesting +x with missing/invalid service credentials also holds autojoins
rather than silently joining without the requested cloak. Without configured
X authentication or a requested +x, the ordinary startup join path remains.

This is **post-registration** authentication, not Undernet Login on Connect.
Deferring autojoins does not promise that the real host was never visible
before authentication. Removing x from configuration does not automatically
remove an already enabled network cloak.

## Periodic recovery and limits

The existing five-second heartbeat drives a monotonic schedule; it creates no
additional persistent timer. After a completed verification, the next check is
scheduled at the configured interval. Actual execution can be later if the
application loop is busy.

- One verification/login/mode operation is in flight per instance.
- WHOIS and mode confirmations each have a 20-second deadline.
- A timeout remains `unverified`; it never infers logout and sends a password.
- A complete negative account result triggers automatic LOGIN when permitted.
- LOGIN attempts have a separate **300-second minimum spacing**, including
  manual requests and shorter configured check intervals.
- There is at most one +x request in a mode-confirmation attempt.
- Invalid credentials, unavailable X or rejected account policies produce
  visible unconfirmed state and bounded retries, not a tight retry loop.
- Disconnect/error/KILL/reconnect invalidates pending state. Old transports
  cannot complete work on a replacement connection. Nick changes cause a new
  check for the actual nickname. Configuration refresh preserves a completed
  initial-join release so it does not duplicate joins.

## Commands and permissions

```text
!xauth
!xauth status
!xlogin
!xlogin status
```

Both names use the same controller. **Authenticated Master or Owner** access
is required, in public and private dispatch. Private syntax uses the normal
query command form, for example `/msg mediabot xauth status`.

The default action requests a check; it does not report success merely because
work has started. `status` is read-only: it reports the controller state,
requested/confirmed +x, interval and age of the last verified account. It does
not print credential values. Account/password arguments are refused. The old
`xlogin <account>` help was misleading: the implementation always used the
configured account. The supported syntax now reflects that contract.

Typical states include `checking`, `login_pending`, `checking_cloak`,
`authenticated`, `not_authenticated`, `unverified`, `cloak_unconfirmed`,
`account_mismatch`, `send_failed`, `not_configured`, `disabled` and
`disconnected`. Logs use bounded `XAUTH state=... reason=...` events. Service
credentials bypass conversation output/logging/rewriting and are sent only via
the IRC transport; diagnostics contain neither account nor password values.

## Offline readiness and the intended production instance

For the **Undernet production bot on teuk.org**, the authoritative instance is:

| Item | Value |
| --- | --- |
| Service | `mediabot@undernet.service` |
| Source | `/home/mediabot/mediabot3` |
| Configuration | `/home/mediabot/mediabot3/mbundernet.conf` |

After updating that source through the normal workflow:

```bash
(
  set -Eeuo pipefail
  test "$(id -un)" = mediabot
  test "$(hostname -f)" = teuk.org
  cd /home/mediabot/mediabot3
  perl tools/xauth_check.pl --conf mbundernet.conf
)
```

The checker uses the native parser, creates no connection and writes nothing.
Its successful output proves configuration readiness only; it explicitly does
not claim live account or mode verification. Missing/invalid Undernet settings
fail the check without displaying their values.

Live acceptance for **this feature is on Undernet**, through that exact bot,
rather than the usual AI acceptance on Epiknet. After the normal commit/update
and restart, inspect `XAUTH` journal events and request `!xauth status` with a
known Master/Owner identity. A healthy periodic check should verify account and
cloak without sending another LOGIN or repeating joins. Keep other instances'
configuration and services separate. Do not provoke a real logout, replace a
live PID file or disclose a password to test recovery; those failure paths use
controlled fixtures.

## Protocol references

- [Undernet X commands](https://www.undernet.org/docs/x-commands-english): the
  server-qualified LOGIN destination and account command.
- [Undernet FAQ](https://www.undernet.org/help/faq_help.php): authenticate to X
  before enabling host-hiding user mode +x.
- [IRC client protocol: WHOIS account](https://modern.ircdocs.horse/#rplwhoisaccount-330):
  the account identity carried by numeric 330.
