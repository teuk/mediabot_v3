# Mediabot v3 Partyline DCC / CTCP CHAT

This document describes the Mediabot v3 Partyline access methods and the DCC CHAT configuration.

The Partyline can be reached through several paths:

```text
telnet localhost <partyline_port>
/dcc chat <botnick>
/ctcp <botnick> CHAT
DCC CHAT chat <ip> <port>
DCC CHAT chat 0 0 <token>
```

The goal is to keep the classic Eggdrop-like feeling while using Mediabot's own user database and permission model.

---

## Login flow

The Partyline now uses an Eggdrop-style login flow.

Instead of typing everything in one command:

```text
login <user> <password>
```

the bot asks for the nickname first:

```text
Mediabot Partyline

Please enter your nickname.
```

Then it asks for the password:

```text
Enter your password.
```

During password input:

```text
the password is not echoed in the terminal
the password is masked in logs
the older login <user> <password> form is still handled for compatibility
```

After successful login, the Partyline displays a welcome message and automatically shows the currently connected Partyline users.

---

## Supported access methods

### Local telnet

If the Partyline TCP port is enabled locally:

```bash
telnet localhost <partyline_port>
```

This is useful for local administration and debugging.

### Active DCC CHAT

From an IRC client:

```text
/dcc chat <botnick>
```

In this mode, the IRC client opens a listening socket and Mediabot connects back to it.

### Eggdrop-style CTCP CHAT

From an IRC client:

```text
/ctcp <botnick> CHAT
```

In this mode, Mediabot opens a temporary DCC CHAT listener and sends a DCC CHAT offer back to the IRC client.

This is the classic Eggdrop-like DCC Partyline workflow.

### Passive/token DCC CHAT

Mediabot also supports passive/token-based DCC CHAT payloads such as:

```text
DCC CHAT chat 0 0 <token>
```

This is useful for IRC clients or bouncers that support passive DCC negotiation.

---

## Required configuration for CTCP CHAT

For `/ctcp <botnick> CHAT`, Mediabot must advertise a public IPv4 address reachable by the IRC client.

Set this in the real Mediabot config:

```ini
DCC_PUBLIC_IP=203.0.113.10
```

On a real server, replace `203.0.113.10` with the server public IPv4 address.

Mediabot also accepts these historical/alternative keys:

```ini
main.DCC_PUBLIC_IP
PARTYLINE_DCC_PUBLIC_IP
main.PARTYLINE_DCC_PUBLIC_IP
```

The environment variable below is also accepted as fallback:

```bash
MEDIABOT_DCC_PUBLIC_IP
```

---

## Optional DCC port range

By default, Mediabot can let the operating system choose a random ephemeral port for DCC CHAT listeners.

For a clean firewall setup, define a fixed DCC port range:

```ini
DCC_PORT_MIN=50000
DCC_PORT_MAX=50100
```

Mediabot will choose a port inside that range.

This makes it possible to open only a controlled range in the firewall instead of relying on random ephemeral ports.

Alternative keys are also accepted:

```ini
main.DCC_PORT_MIN
main.DCC_PORT_MAX
PARTYLINE_DCC_PORT_MIN
PARTYLINE_DCC_PORT_MAX
main.PARTYLINE_DCC_PORT_MIN
main.PARTYLINE_DCC_PORT_MAX
```

---

## Firewall note

If `DCC_PORT_MIN` / `DCC_PORT_MAX` are configured, the same TCP range must be reachable from IRC clients.

Example:

```ini
DCC_PORT_MIN=50000
DCC_PORT_MAX=50100
```

Then TCP ports `50000:50100` must be allowed from the outside.

Do not touch the SSH port when adjusting firewall rules. On teuk.org, SSH access is on TCP `52001` and must remain protected.

---

## Anti-spam behavior

Mediabot tracks pending DCC CHAT offers in memory.

A single nick cannot open unlimited DCC listeners by repeating:

```text
/ctcp <botnick> CHAT
```

If a DCC offer is already pending for that nick, Mediabot refuses to create a new one until the current offer is used or times out.

This prevents accidental or intentional listener spam.

---

## `.dccstat` command

The Partyline provides a diagnostic command:

```text
.dccstat
```

Alias:

```text
.dcc
```

It displays:

```text
DCC public IP
DCC port mode
pending DCC offers
active DCC sessions
active telnet sessions
```

Example output:

```text
DCC Partyline status:
  Public IP      : 203.0.113.10
  Port mode      : 50000-50100 (DCC_PORT_MIN/MAX)
  Pending offers : 0
  DCC sessions   : 1
  Telnet sessions: 0
```

This is useful for debugging CTCP/DCC behavior without digging through logs.

---

## Expected CTCP CHAT log flow

When `/ctcp <botnick> CHAT` works correctly, logs should look like:

```text
CTCP CHAT request from <nick> via raw CTCP payload
CTCP CHAT from <nick> (level=Owner): offering DCC CHAT
CTCP CHAT from <nick>: opening DCC CHAT offer on <public_ip>
CTCP CHAT: listening on port <port> for <nick>
CTCP CHAT: sent DCC CHAT offer to <nick> ip_int=<integer> port=<port>
```

Then the IRC client should open a DCC CHAT window and display the Partyline login prompt.

---

## Troubleshooting

### CTCP request is seen as private command `chat`

If logs show:

```text
Private command 'chat' not found
```

then the raw CTCP `CHAT` payload is not being intercepted early enough before the private command parser.

The expected raw payload is:

```text
\x01CHAT\x01
```

Mediabot must detect it before command dispatch.

### Cannot determine public IP

If logs show:

```text
cannot determine public IP
```

set:

```ini
DCC_PUBLIC_IP=<server_public_ipv4>
```

### DCC offer is sent but client never connects

If logs show:

```text
CTCP CHAT: listening on port <port>
CTCP CHAT: sent DCC CHAT offer
CTCP CHAT: timeout waiting for <nick> to connect
```

then the DCC offer was generated, but the client could not reach the announced port.

Check:

```text
DCC_PUBLIC_IP
DCC_PORT_MIN / DCC_PORT_MAX
firewall rules
NAT / routing
IRC client DCC settings
```

### Password appears on screen

For telnet-based Partyline sessions, Mediabot negotiates TELNET ECHO off during password input.

If the password still appears, the client may not honor TELNET ECHO negotiation.

Try a standard telnet client first.

---

## Security notes

The Partyline now avoids the obvious password leaks:

```text
password input is not echoed
password input is masked in logs
legacy login <user> <password> is masked if typed
```

DCC CHAT access is still protected by Mediabot authentication and global user level checks.

Keep DCC ports restricted to the smallest useful range.

---

## Finding commands and using session history

The same tools are available after authentication on Telnet and DCC CHAT.
They use the existing help text and per-connection memory; no database schema
or persistent storage is required.

| Command | Result |
| --- | --- |
| `.help` | Full command list. |
| `.help plugins` | Help lines for the exact command. A leading dot is optional. |
| `.help dcc` | Help for the existing `.dccstat` / `.dcc` alias. |
| `.help search timer` | Literal, case-insensitive search in command names and descriptions. |
| `.history` | The last ten recorded commands in the current session. |
| `.history 5` | The five most recent retained commands, oldest first. |
| `.history find café` | Literal, case-insensitive search in the retained history, including valid UTF-8. |
| `.history clear` | Clear only this connection's in-memory history. |

Help search returns at most twelve lines and asks you to refine broader matches.
Search text is limited to 128 characters. Session history retains ten commands;
it cannot retrieve older commands, history from another connection, or history
from a previous login. History requests are neither recorded in that history nor
announced to other Partyline users. Server-side input logging retains its existing
policy. No history operation re-executes a stored command.

These tools keep the normal authentication and rate limits. They do not change
the permissions or execution of the commands described in the help output.

---

## Connection presence and session filters (MB904)

Authenticated Telnet and DCC users can mark one connection away and filter the
existing session list. These commands use memory only, with no database or
configuration change.

| Command | Result |
| --- | --- |
| `.away` | Mark this connection away with the default reason `Away`. |
| `.away Maintenance en cours` | Set or update the reason, visible to other authenticated Partyline users. |
| `.back` | Clear this connection's away state. |
| `.whom` or `.whom all` | All authenticated sessions; away sessions show their reason. |
| `.whom away` | Away sessions only. |
| `.whom here` | Sessions without an away state. |
| `.whom telnet` | Telnet sessions only, whether away or here. |
| `.whom dcc` | DCC sessions only, whether away or here. |

Filters are case-insensitive and select a single category. With no away users,
the original unfiltered `.whom` output is preserved. Presence is independent for
two connections using the same account and disappears on disconnect; it is not
published to IRC or persisted in the runtime-status JSON. Chat and commands still
work while away; chatting does not automatically clear the away state.

Reasons must be valid UTF-8, without control characters, and at most 160 encoded
bytes (for example, 40 four-byte emoji). Oversized or invalid reasons are refused
without changing the previous state or announcing the rejected input to peers.
Only real state changes are announced: repeating the same reason or `.back`
while already here does not create another announcement. Reasons are public to
authenticated Partyline peers. Presence commands use the existing session history,
server logging and rate limits; `.history` privacy rules remain unchanged.

---

## Quick validation checklist

After changing DCC settings or Partyline code:

```bash
cd /home/mediabot/mediabot_v3

perl -I. -c mediabot.pl
perl -I. -c Mediabot/Partyline.pm
perl -I. -c Mediabot/Mediabot.pm
```

Then test from IRC:

```text
/ctcp <botnick> CHAT
```

Then inside the Partyline:

```text
.dccstat
.dcc
.help
```

Expected results:

```text
the DCC offer is created
the IRC client connects
the password is hidden
.dccstat shows the public IP, port mode, pending offers and active sessions
```

## Private channel diagnosis (MB938)

Authenticated Master/Owner sessions can use `.diagnose #channel` and
`.help diagnose` for a read-only, bounded view of persisted chansets and
observed IRC/JOIN state. Only the requester receives the report; the request
is not announced to other sessions. `on`, `off`, `missing` and `unknown` are
separate observations, with no provider probe or setting change. See
[Channel diagnostics](CHANNEL_DIAGNOSTICS.md) for scope and interpretation.
