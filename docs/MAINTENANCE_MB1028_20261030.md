# MB1028 — Short IRC emphasis and literal Markdown markers

Source: `snap_mediabot_v3_teuk_20261030_174949.zip`, matching public master
`0017a5d04085266cdd03d64d406a9a1a5d32a174`, already in 3.8dev.

The shared Markdown-to-IRC renderer required at least two characters in an
emphasis body. Consequently `**A**` became italic `*A*`, `*B*` remained plain
with its stars and `++E++` retained its underline markers. Single accented
characters and emoji were affected too. The closing non-space boundary now
uses a lookbehind, allowing the same character to satisfy both boundaries
while retaining minimal matching and separate adjacent spans.

A second ordering error restored escaped literal characters before removing
unescaped scaffolding. An escaped `\*\*A\*\*` therefore lost its stars and an
escaped backtick pair disappeared. Literal restoration now follows that
cleanup. The final IRC control filter still runs after restoration.

Nine focused assertions exercise the real shared owner and the existing AI
compatibility facade. Six fail on the original implementation. Coverage includes
short bold/italic/underline spans, accented text and emoji, adjacent and mixed
spans, escaped double markers/backticks/strike markers, mixed literal/styled
content, long and nested spans, intraword underscores, 120/400-byte budgets,
the two-line cap, control filtering and the plain truncation suffix.

No provider implementation or prompt, API call, model, command, schema,
configuration, IRC transport, README/banner, polling or published release is
changed. The existing facade still aliases the shared renderer. Full-suite
success and audits precede the fixed dev-only restart and normal native
commit.sh automatic mode, continuing 3.8dev without editing VERSION manually.
