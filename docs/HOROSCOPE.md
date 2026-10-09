# Compact daily horoscope

`horoscope` and its short alias `horo` show two lines: the zodiac sign and its
forecast, then lucky number, colour, luck percentage and companion sign.

```irc
!horoscope
!horoscope Pablo
!horoscope lion
!horo aries
!horoscope bélier
```

No argument uses the caller's registered birthday. A nickname uses that user's
birthday. An explicit sign wins over any stored birthday. French, English and
Spanish sign names, zodiac glyphs and the existing abbreviations are accepted;
input spelling does not select the output language.

## Channel language and output

The existing channel language policy applies: `+LangFR` selects French;
otherwise the bot uses `main.LANG`. French displays French sign names and lucky
labels, English displays English ones. For example, the same command can render
as follows (illustrative wording and lucky values):

```text
♌ Lion · 2026-10-08 · pablo — Votre assurance entraîne les autres. Partagez la lumière avec ceux qui vous accompagnent.
🍀 Nombre 42 · Couleur indigo · Chance 79% · Complice Balance
```

```text
♌ Leo · 2026-10-08 · pablo — Your confidence inspires others. Share the spotlight with those beside you.
🍀 Lucky number 42 · Colour indigo · Luck 79% · Kindred sign Libra
```

There is no additional element slogan, mood line, advice paragraph or repeated
introduction. Each payload is at most **400 UTF-8 bytes**, including its prefix;
long forecasts are shortened at word boundaries without splitting accents or
emoji. Ordinary PRIVMSG helpers still apply channel formatting and flood policy.

The same sign/day shares its fallback forecast across users. Lucky details
remain deterministic per target and day, with the historical draw order; changing
FR to EN does not reshuffle them. The bot's existing local calendar date remains
the day key. No new timer, state file or database migration is needed.

## External forecast and local fallback

The bot tries its existing horoscope providers, or the configured
`horoscope.API_URL` template containing `%s`. A response explicitly naming another
sign is refused. Existing `horoscope.TIMEOUT` is respected up to eight seconds
per attempt (six seconds by default).

An English prediction needs no translation. For French, the first configured
AI provider in `anthropic`, `openai`, `gemini` order makes one synchronous,
stateless translation request **inside the command worker**, bounded to eight
seconds. It does not enter the chat conversation or use history, personas, pins
or deferred output callbacks. OpenAI model fallback is disabled for this request.
The existing Spanish external translation path remains supported; local cards
and compact labels currently cover FR/EN, with English as the other-language
fallback as before.

Missing credentials, timeouts, invalid results or rejected translation use the
local forecast in the display language. Local cards are specific to all twelve
signs and rotate deterministically with the date. They are playful bot-generated
forecasts, not a claim that an external prediction was received. Failed optional
providers do not add public error announcements.

An unknown or invalid birthday does not invent a sign. The compact reply invites
an explicit sign command and still shows the existing generic lucky details,
without a companion sign. Existing supported birthday formats are retained:
`MM-DD`, `YYYY-MM-DD` and legacy `DD/MM[/YYYY]`.

## Access and development acceptance

Public use retains the `+Games` gate and the existing asynchronous dispatch for
both aliases. Internal private calls retain private routing and the global
language; this change adds no new PM command registration or access permission.
Consultation counters, achievements and metrics retain their existing hooks.

After applying and passing the source checks, restart only the development
instance in a separate step. Compare `!horoscope lion` and `!horo bélier` on an
existing FR channel and an existing EN channel, then try a registered nickname
with a birthday and one without. Confirm two compact lines, correct sign names,
clean accents and a localized fallback when no translation key is configured.
A running instance must be restarted to load the changed Perl modules.

Source validation:

```bash
perl t/test_commands.pl --filter 'mb817|mb444|mb561|mb572|mb620|mb621|mb622|mb631' --progress
perl t/test_commands.pl --fast --progress
perl t/test_commands.pl --progress
```

Commit only after development acceptance, using the repository's `commit.sh`
workflow. Production updates remain a separate operator action.
