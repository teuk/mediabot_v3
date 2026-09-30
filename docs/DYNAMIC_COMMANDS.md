# Dynamic commands (MB807)

Dynamic commands are stored in `PUBLIC_COMMANDS`; no schema migration is needed.
Use your instance's configured trigger (`!` in the examples). Management also
works with `/msg <botnick> <command> ...`.

## Create and edit

```
!addcmd café action general fait un café super bon pour %n !
!modcmd café action general sert un café %choose{serré|allongé|décaféiné} à %target% !
!addcmd décision message general %nick%, ma réponse est %yesno%.
!addcmd dé message general %nick% obtient %rand{1,6} !
!addcmd météo_du_jour message general %choose{soleil|pluie|neige} sur %channel%.
```

Syntax for both `addcmd` and `modcmd` is
`<command> <message|action> <category> <text...>`.
`message` sends a PRIVMSG; `action` sends an IRC `/me`. Neither permits an
arbitrary IRC target. Categories must already exist (`addcatcmd general`).

Names accept Unicode letters, combining marks after the first character,
digits, `_` and `-`, with a limit of 64 characters after NFC normalisation.
`café` and `cafe` followed by a combining acute accent identify the same name.
MySQL/MariaDB's existing `utf8mb4_unicode_ci` collation also determines case and
accent equivalence: the bot does not create a separate binary naming scheme.
Names that public dispatch resolves to a built-in or loaded plugin (including
aliases and accented built-in spellings) cannot be added or used as rename
targets. Existing dynamic commands remain manageable.

Text is limited to **244 Unicode characters**, leaving room for the stored
`PRIVMSG %c ` prefix in the existing `VARCHAR(255)` action column. Both creation
and modification check this limit, valid UTF-8, control characters and random
syntax before writing anything. IRC formatting (bold, colours, etc.) remains
available; CR, LF, NUL and CTCP delimiters are rejected.

## Variables

| Variable | Meaning |
|---|---|
| `%n` | All arguments joined by spaces; caller's nick when there are none (legacy behaviour) |
| `%N`, `%nick%` | Caller, even when arguments are supplied |
| `%target%` | First argument, or caller if absent |
| `%args%` | All arguments, or empty text if absent |
| `%1` … `%9` | Individual argument; empty if missing |
| `%c`, `%channel%` | Invocation channel |
| `%command%` | Command name |
| `%s` | Command name with `_` replaced by spaces |
| `%r`, `%R` | Random member of the invocation channel; caller if unavailable |
| `%date%`, `%time%` | Bot's local date (`YYYY-MM-DD`) and time (`HH:MM`) |
| `%yesno%`, `%on` | Random `oui` or `non` |
| `%bool%`, `%b`, `%B` | Random `true` or `false` |
| `%rand{min,max}`, `%random{min,max}` | Random integer with both bounds included |
| `%choose{a|b|c}`, `%choice{a|b|c}` | One literal option |
| `%d`, `%dd`, `%ddd` | Legacy ranges **1–10**, **10–99**, **100–999** |
| `%%` | A literal percent sign; `%%n` prints `%n` |

Random bounds must be integers satisfying
`-1000000 <= min <= max <= 1000000`. Equal bounds are allowed. Choices require
2–20 non-empty options. Inside a choice, escape literal delimiters with
`\|`, `\{`, `\}` and `\\`. For example `%choose{a\|b|c}` chooses `a|b` or `c`.
A draw works immediately before punctuation, e.g. `%rand{1,6}!` or `%d!`.

Each occurrence of the explicit `%rand{...}`, `%choose{...}`, `%yesno%` and
`%bool%` variables draws independently. Repeated legacy `%on`, `%b`, `%B`,
`%r` or `%R` reuse their respective first value within one invocation.
Legacy numeric variables still draw independently.

Values are inserted **once**. Arguments, nicknames and choice values cannot
introduce another template expansion. `%choose{bonjour %n|salut %n}` therefore
contains literal `%n`; instead use `%choose{bonjour|salut} %n`.
Nested choices and expressions are unsupported. There is no Perl, shell or
arithmetic evaluation; unknown named placeholders such as `%unknown%` remain
literal. Rendered output is capped at 4096 characters, then follows the normal
IRC sender's UTF-8 splitting, channel settings and flood handling.

## Inspect and administer

| Command | Behaviour / access |
|---|---|
| `cmdvars` | Public variable reference, sent privately by NOTICE |
| `testcmd <command> [arguments...]` | Administrator+: private preview, including held commands; no hit or database writes |
| `showcmd <command>` | Public raw template, owner, category, hits, date and status |
| `holdcmd <command> [on\|off\|toggle]` | Administrator+: `on` disables, `off` reactivates; default is `on` |
| `mvcmd <old> <new>` | Master+: rename after Unicode, reserved-name and duplicate checks |
| `chowncmd <command> <username>` | Master+: ownership transfer; system-owned commands are supported |
| `chcatcmd <new_category> <command>` | Administrator+: change category; historical category-first order retained |
| `addcatcmd <category>` | Administrator+: create a category (one Unicode token, max 64 characters) |
| `remcmd <command>` | Administrator+: owner only, or Master+ |
| `modcmd ...` | Administrator+: owner only, or Master+; same validation as addcmd |
| `searchcmd <keyword...> [limit=5]` | Public literal search in names **and** templates; limit 1–20; `%`, `_` and `!` escaped |
| `countcmd`, `topcmd`, `lastcmd`, `owncmd`, `popcmd`, `showcommands` | Existing statistics/list commands and pagination retained |

```
!testcmd café Alice
!café Alice
!holdcmd café on
!testcmd café Bob
!holdcmd café off
!cmdvars
!help addcmd
```

In a private `testcmd` context no channel can be inferred: `%channel%` is empty
and a random nick falls back to the caller. Public execution remains confined
to the invocation channel. A malformed stored template is handled without
sending output or increasing hits. Valid invocations increment hits atomically;
a failure to update statistics is logged and does not suppress the reply.
