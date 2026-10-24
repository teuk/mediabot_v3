# Offline Spark replay (MB798)

MB798 takes an operator-supplied, anonymized JSON Lines history and replays
the production conversation exclusion boundary, Spark observer, state and
orchestrator with a virtual monotonic clock. The tool constructs no generator,
provider, IRC connection or sender. Candidate results are policy evidence only.
It changes neither process send arm nor channel capability.

MB805 takes `main.MAIN_PROG_CMD_CHAR` from the supplied instance configuration
when classifying the bot's own commands. Thus a configured `#rss` contributes
short command pressure rather than human conversation in a replay, just as it
does at runtime. The synthetic fixture
below has no prefix setting and retains the historical `!` default. An invalid
configured prefix fails the replay instead of counting command traffic as
conversation.

The synthetic fixture is tracked as `.txt`: `commit.sh` deliberately removes
`.conf` files from source commits to protect live configuration. Copy the
fixture to a private temporary `.conf` for the real config reader. From the
Mediabot source directory on development:

```sh
(
  set -Eeuo pipefail
  umask 077
  example_conf="$(mktemp /home/mediabot/mb798-example.XXXXXX.conf)"
  trap 'rm -f -- "$example_conf"' EXIT
  cp tools/fixtures/mb798_spark_replay.txt "$example_conf"
  perl tools/mb_spark_replay.pl \
    --config "$example_conf" \
    --input tools/fixtures/mb798_spark_replay.jsonl \
    --channel '#room' --bot-nick Mediabot
)
```

Supply a **copy of the target instance's config** when testing its exclusions;
the included fixture is synthetic and says nothing about `nbot` or `#i/o`.
The input is a sequence of at most 256 JSON objects, one per line, sorted by
integer `at` seconds from 0 to 604800. A public line has `type:"line"`,
`nick` and `message` (at most 240 characters). Set `from_bot:1` only for
nonexcluded automation that should contribute bot pressure. A probe has
`type:"probe"` and `at`. Give nicknames generic aliases and replace content
with benign sample phrases while preserving command or address prefixes;
never paste private chat logs. The tool emits decisions and counters, no input
messages or nicks, and fails on malformed or oversized input.

The replay evaluates both Spark policy lanes at each probe and records any
second momentum candidate in the same unchanged human activity window as an
error (exit 2). Excluded lines reach neither observer nor flood guard. A
nonexcluded bot line still delays momentum through bot pressure. No generated
text is assessed here: this tool cannot demonstrate live delivery, provider
quality or actual runtime reloads. A change to nbot requires separate evidence
and authorization.

## Configuration de cadence et sorties du bot (MB949)

Le replay et le runtime lisent désormais les mêmes neuf clés dans une frontière
partagée ; Orchestrator garde les mêmes bornes et valeurs de repli :
SPARK_MIN_SILENCE_SECONDS, SPARK_CANDIDATE_PROBE_SECONDS,
SPARK_ACTION_ACTIVITY_WINDOW_SECONDS, SPARK_ACTION_MIN_HUMANS,
SPARK_ACTION_MIN_LINES, SPARK_ACTION_MIN_PAUSE_SECONDS,
SPARK_ACTION_MAX_PAUSE_SECONDS, SPARK_ACTION_PROBE_SECONDS et
SPARK_ACTION_COOLDOWN_SECONDS, toutes dans [main]. Avant MB949, le replay lisait
les exclusions et le préfixe mais utilisait les défauts de cadence, même avec
une autre valeur dans le fichier fourni. Un essai pouvait donc annoncer une
candidature trop tôt ou trop tard par rapport au runtime visé.

Un événement facultatif décrit maintenant une sortie locale acceptée par la
façade IRC, comme le signal utilisé depuis MB943 :

```json
{"at":40,"type":"output","accepted":1}
```

Il ne contient ni texte, ni nick, ni autre champ. accepted doit être exactement
0 ou 1. Une sortie refusée ou seulement différée est décrite avec 0 et n'ajoute
aucune pression ; 1 appelle le véritable note_bot_pressure de l'observateur.
Cela retarde les deux familles de candidatures sans créer de participant ni
un salon observé si aucune conversation n'y a été vue. Une acceptation de la
façade n'est pas un accusé de réception du serveur IRC.

Cet événement est distinct d'une ligne reçue d'un autre bot, qui garde son
chemin from_bot et ses exclusions. Ne pas représenter une même sortie à la
fois comme output et comme ligne entrante : on compterait deux événements.
Le rapport conserve sa forme et ne restitue aucun texte ou identité de l'entrée.

Le test natif MB949 compare les neuf options au véritable constructeur appelé
par _spark_runtime dans mediabot.pl, puis vérifie les scénarios calme, actif,
pression du bot et commandes. Le replay reste une simulation de candidatures,
avec portes de salon supposées ouvertes : il ne lit pas CHANNEL_SET, ne choisit
pas un profil en base et ne mesure ni pertinence ni répétitions de texte généré.
Les profils MB948 s'évaluent ensuite en situation, sur l'instance concernée.
