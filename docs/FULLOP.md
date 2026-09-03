# `+Fullop` open-channel policy

`+Fullop` is an opt-in channel policy for communities that deliberately give
IRC operator status to everyone while keeping joining and speaking open.

It is disabled everywhere by default. Registering the chanset does not enable
any channel.

## Behaviour

When `+Fullop` is enabled on a channel, Mediabot:

- gives `+o` to every new joiner;
- immediately sweeps the current NAMES list when the chanset is enabled;
- lets ordinary users kick, change the topic and use harmless channel modes;
- reverses an ordinary user's ban, quiet, mute, invite-only, moderated, key,
  limit, redirect, join-throttle or equivalent join/speech restriction;
- also repairs an unauthorized deop or higher-status change;
- writes `nick: hey ho, c'est pas le genre de la maison` to the channel;
- stores a normal persistent channel ban for the actor, then bans and kicks
  that actor with the same reason for ten minutes.

One incoming MODE line causes at most one sanction even when it contains
several protected changes. The existing channel-ban expiry worker removes the
temporary ban after its deadline.

The IRC `+b` is emitted only after the ten-minute sanction is durable in the
existing channel-ban store. If another active durable ban already covers the
actor, Mediabot reuses that row's exact stored mask so the expiry worker later
removes the same IRC mask. If persistence fails, Mediabot still reverses the
restriction, warns the actor and kicks them, but deliberately refuses to
create an unmanaged IRC ban that could outlive its intended expiry.

## Privileged exceptions

A restrictive MODE is accepted only when the actor resolves to an
authenticated Mediabot identity that is either:

- a global `Administrator`, `Master` or `Owner`; or
- assigned access level 75 or greater on that channel.

Nickname text alone never grants the exception. Server-origin MODE lines,
Mediabot's own corrections and configured service identities are trusted.

Raw IRC `KICK` remains allowed for ordinary ops. `+Fullop` intentionally does
not turn a friendly kick into a ban.

## Network-aware mode parsing

Mediabot consumes the server's numeric 005 (`ISUPPORT`) values:

- `NETWORK` selects the conservative network profile;
- `PREFIX` distinguishes member statuses from list modes, especially `q`;
- `CHANMODES` determines which signs consume parameters;
- `MODES` bounds each batched current-user op sweep.
- `CASEMAPPING` deduplicates channel and nickname identities with the server's
  advertised IRC case rules.

Numeric 324 seeds the current parameter-bearing channel state. That lets the
guard restore an existing key, limit, redirect or throttle after an
unauthorized removal or replacement instead of guessing its old value.

The baseline covers RFC ban/exemption, invite-only, key, limit and moderated
modes. Libera/Solanum, Undernet and EpiK/InspIRCd profiles add their known
join/speech restrictions. An extended mute implemented as a ban mask is
already covered by the protected `b` list.

## Configuration

The public sample contains:

```ini
[fullop]
BAN_SECONDS=600
TRUSTED_SERVICE_MASKS=
PROTECTED_MODES=
```

`BAN_SECONDS` is clamped to 60–3600 seconds. The shipped and deployed default
is 600 seconds (ten minutes).

`TRUSTED_SERVICE_MASKS` is a comma- or space-separated list of complete IRC
glob masks, for example a network's actual ChanServ prefix. Leave it empty when
all service channel modes are server-origin. Undernet X and Libera ChanServ
have narrow built-in profiles; site-specific services should be listed
explicitly before enabling `+Fullop`.

`PROTECTED_MODES` can add site-specific mode letters to the selected network
profile. It cannot remove the baseline safety modes.

## Activation

After applying `install/migrations/20260903_fullop_chanset.sql`, an authorized
Mediabot operator can enable one channel explicitly:

```text
chanset #channel +Fullop
```

Before activation, verify that Mediabot itself has durable operator rights and
configure any user-prefixed channel service mask. Disable with:

```text
chanset #channel -Fullop
```

Disabling stops new Fullop actions; existing ten-minute sanctions remain
normal `CHANNEL_BAN` rows and expire through the usual worker.
