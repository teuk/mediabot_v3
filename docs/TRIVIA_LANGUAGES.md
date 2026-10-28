# Trivia in French and English

English continues to use the complete **Open Trivia DB** remote source. French
adds a separate, local **OpenQuizzDB** catalog: 6,044 questions, 14 categories,
three difficulty levels. Neither source replaces the other.

## Commands

```text
!trivia fr
!trivia fr histoire difficile
!trivia fr informatique facile
!trivia fr categories
!trivia fr start 5
!trivia en
!trivia en science hard
!trivia en categories
!trivia fr myscore
!trivia fr leaderboard
!triviastop
```

The optional language is the first argument. Without it, a new game keeps the
historical English source, regardless of `main.LANG` or language chansets. An unfinished multi-round series keeps its selected language
for subsequent plain `!trivia` commands. An explicit language chooses the next
question; it never overwrites a live question or pending request.

The existing multi-round progression is unchanged: after an answered/expired
question, request the next one with `!trivia`. French selection does not add
automatic rounds. `!triviastop` retains its authenticated Master requirement
and cancels live, pending and between-question series as established by MB983.

French categories: culture, littérature, cinéma, musique, télévision, jeux,
sciences, informatique, mythologie, sports, géographie, histoire, arts, animaux.
English aliases such as `history`, `computers`, `film` and `books` also work
for supported French categories. Use `facile`, `moyen`, `difficile` or the
existing `easy`, `medium`, `hard` difficulty names. A category not represented
in the French catalog is explicitly refused; it remains available in English
where supported by the original source.

## Answers and scores

Type the answer in the channel. French questions accept case differences,
missing accents, repeated spaces, straight/curly apostrophes and OE/Œ or AE/Æ
ligatures. The original accented answer remains visible in hints and results.
Embedded longer words do not become correct answers. English matching retains
its existing behavior.

Both languages use the same existing `TRIVIA_SCORES` table and channel/nickname
keys. Switching sources does not erase or import scores. No schema, account,
grant or configuration change is needed. Session scores and cumulative scores
retain their existing distinct behavior and reset authorization.

## French catalog and runtime

French selection runs inside the existing Trivia worker. The IRC loop does
not parse the multi-megabyte catalog. Requests need neither an API key nor a
network service. The last 64 French question ids are avoided per channel while
matching fresh choices remain; if a filtered pool is exhausted it can repeat.
Cancelled or stale completions do not consume a new request or open a question.

This catalog is a pinned **2022-02-12 archival selection**, not the latest
OpenQuizzDB export. See [data provenance, authors and licensing](../Mediabot/Games/data/README.md).
The questions come from OpenQuizzDB rather than generated translations. Their
wording and answers are retained after documented structural/IRC filtering;
this does not certify every source fact. The reproducible builder supports an
explicitly reviewed future catalog update without any SQL import.

The English URL, source parser, full category range and HTTP/rate-limit retry
path stay in `Mediabot/External/OpenTriviaDB.pm`. A French catalog failure is
reported in French and never silently replaced by an English question.
