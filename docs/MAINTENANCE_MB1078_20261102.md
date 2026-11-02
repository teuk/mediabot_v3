# MB1078 — Réessayer la présence d'une identité après un échec SQL

Base : snap_mediabot_v3_teuk_20261102_184852.zip.
VERSION : 3.8dev-20261102_171901. Les 395 chemins précédemment qualifiés
correspondent à MB1077 final ; tous les correctifs antérieurs sont conservés.

## Défaut

Sur une identité déjà reconnue, _touch_seen_alias mettait à jour last_seen_at
dans ACHIEVEMENT_IDENTITY puis ACHIEVEMENT_PROFILE. Les retours d'execute
étaient ignorés et le cache de dernière écriture était mis à jour malgré une
panne. La prochaine observation pouvait donc attendre une heure avant de
réessayer une présence jamais sauvegardée. RaiseError pouvait aussi échapper
de prepare. Aucun finish explicite n'était tenté sur ces statements.

## Correction

Les deux UPDATE sont toujours tentés indépendamment et restent idempotents.
Chaque préparation/exécution est protégée ; le résultat et err sont décidés
avant cleanup, et finish est tenté pour chaque statement acquis. Le timestamp
de cache et le display local ne sont publiés que si les deux writes réussissent.
En cas de panne, l'ancien cache est conservé et l'observation suivante réessaie
immédiatement les deux écritures. Une exception de cleanup ne masque pas le
résultat SQL décidé auparavant.

Les UPDATE ne deviennent pas transactionnels : une écriture peut persister
alors que l'autre échoue. Le retry est idempotent. Aucun commit/rollback ni
changement d'attribut DBI n'est ajouté ; cette méthode ne garantit pas le commit
d'une transaction possédée par un appelant.

La fenêtre de 3 600 secondes demeure après une écriture confirmée, sauf si le
stamp est dans le futur après un recul de l'horloge. Dans ce cas le touch est
réarmé. Les clés restent propres au triplet canal/nick/userhost et les binds
ciblent les mêmes identité/profil. L'absence de DBH retourne 0.

observe_identity conserve le profil reconnu même si ce touch best-effort
échoue. Aucune attribution, fusion, autorisation ou reconnaissance d'identité,
aucun compteur/unlock ou import d'achievement n'est changé.

## Tests natifs

Le probe enfant MB932 existant passe de 11 à 15 groupes, sans nouveau processus.
Le test 826 regroupe cinq conditions de compatibilité en une assertion, huit
contrats de schéma/migration en quatre et trois marqueurs publics en un. Toutes
les conditions restent présentes. Quatre groupes natifs sont ajoutés :

- succès, binds exacts, cleanup, fenêtre horaire et frontière exacte ;
- prepare refusé par l'authorizer SQLite et execute refusé par des triggers,
  sur chaque table avec RaiseError 0/1 ; succès partiels, ancien cache retenu,
  reconnaissance conservée, retry à l'observation suivante et absence de
  modification des autres profils/identités ou de tout le mérite ;
- finish natif puis exception de cleanup, après succès ou échec SQL ;
- recul d'horloge, reprise de la fenêtre normale et isolation des identités
  et des canaux.

Les vrais méthodes, DBI et requêtes sont exécutés. Seul NOW est adapté à une
fonction SQLite et l'horloge est fixée dans le processus de probe isolé. Le
RootClass observe les binds et finish ; il ne remplace pas l'algorithme du
cache. Les 11 groupes transactionnels précédents restent inchangés.
Le cas passe de 43 à 37 assertions : six de moins. Aucun nouveau cas ni attente.
QUALIFICATION.md donne les mesures réelles et limites de la full locale.

## Exploitation

Aucun schéma, dépendance, configuration ou donnée de mérite à modifier.
VERSION, README racine, commit.sh privé, runner/ETA, radio, YouTube, logger,
rôles MB1077 et minuteurs MB1075 sont conservés.

Le paquet vérifie les contenus exacts avant/après et les anciens changements
qualifiés en attente. Full visible --progress/ETA sans redirection, audits,
inventaire et whitespace avant staging/restart. Ensuite dev seul, nouveau PID
stable dix secondes, commit.sh natif --skip-preflight et VERSION automatique
3.8dev. Un PID stable ne prouve pas la reconnexion IRC.
