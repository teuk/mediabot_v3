# French Trivia data — OpenQuizzDB

`trivia-fr.json` contains 6,044 French questions selected from 206 OpenQuizzDB
quizzes. This data is **CC BY-SA 4.0**, separately from Mediabot's code license.
The full data license is in `CC-BY-SA-4.0.txt` and at
<https://creativecommons.org/licenses/by-sa/4.0/>.

Original provider: **OpenQuizzDB**, <https://www.openquizzdb.org/>.

Original quiz authors represented in this selection:
Philippe Bresoux, Catherine De Smeytere, Alexandre Verfaillie, Geremia Fortunato,
Corentin Declercq, Edouard Swit, Nicolas Humbert, Gérard Le Bras and Damien Moreau.
Every question retains its author and theme. The `sources` list retains the
individual quiz titles, authors, source filenames, pinned source links and
SHA-256 digests of the original JSON files.

## Exact provenance and age

This is an **archival selection**, not a live/current export of OpenQuizzDB.
It comes from <https://github.com/Zeuh/OpenQuizzDB>, commit
`a16819964d171e40e6652368fc562f3bd27d0c5b`, dated **2022-02-12**.
The mirror attributes its data to OpenQuizzDB and distributes it under the
same CC BY-SA 4.0 terms. The original provider's current licensing page is
<https://www.openquizzdb.org/licence/>.

No generated questions or automatic translations have been added. This is
source content and can contain historical inaccuracies or outdated facts;
structural validation does not certify every factual answer. Current-events
and adult-oriented quiz collections were not selected for this catalog.

## Changes made for Mediabot

- Extract French only, including the older single-language JSON layouts.
- Map beginner/confirmed/expert to easy/medium/hard and assign the 14 game
  categories. Preserve the original theme and author separately.
- Normalize whitespace. Retain question wording and original correct answers.
- Omit invalid JSON sources, invalid/control-character text, repeated questions,
  ambiguous choices after accent folding, and questions/choices exceeding IRC
  byte budgets. `skipped` records the excluded quiz/question identifiers.
- Do not retain the optional explanatory anecdotes; the game uses the QCM.

Derived data remains CC BY-SA 4.0. Preserve these credits and the license when
redistributing or updating it. The game also identifies OpenQuizzDB and links
the data license at the start of a French game.

## Reproduce the selection

From a clean checkout of the source revision above:

```sh
python3 tools/build_trivia_fr_catalog.py \
  --source-root /path/to/OpenQuizzDB \
  --output /tmp/trivia-fr.json
cmp Mediabot/Games/data/trivia-fr.json /tmp/trivia-fr.json
```

The builder reads JSON only: it performs no network request and imports no SQL.
Updating to another source revision requires reviewing its content, license,
mapping, filters and pin explicitly, then regenerating and testing the catalog.
