# MB934 — Reports de rappels fiables

Base : `snap_mediabot_v3_teuk_20261023_192039.zip`, VERSION
`3.6dev-20261023_171917`. Aucun changement du schéma de base de données.

## Revue et défauts retenus

La revue générale a poursuivi les lectures du scheduler, du bus d'événements,
du stockage/polling RSS, de RandomQuote, du raccourcisseur et des commandes
communautaires. Les corrections de ce round portent sur des défauts reproduits
dans `remindsnooze` ; ce passage n'atteste pas que tous les autres chemins sont
exempts de bugs.

Le délai était lu par quatre recherches indépendantes non ancrées. `-1h`
devenait une heure positive, `1.5h` cinq heures et du texte supplémentaire ou des
unités répétées pouvait être ignoré. Une durée énorme pouvait produire `[at:Inf]`,
que le livreur ne reconnaît pas comme une date future : le rappel pouvait alors
être considéré immédiatement livrable.

Entre SELECT et UPDATE, une livraison, une annulation, une suppression ou un
changement de propriétaire peut rendre le rappel non modifiable. L'UPDATE DBI
réussit alors avec zéro ligne, mais la commande annonçait tout de même un report.
Les exceptions SQL et erreurs de fetch n'étaient pas toutes traitées localement.

## Correction

Le token complet doit maintenant être une somme de quantités entières positives
ou nulles suivies de d/h/m/s, avec chaque unité au plus une fois et un total
strictement positif. Un plus initial reste accepté, tout comme l'ordre libre
des unités existant. Les formats documentés `1h`, `30m`, `2h30m`, `1d` et `1s`
gardent leur durée. Les saisies partielles, négatives, fractionnaires, répétées,
supplémentaires et les dates non représentables par `[at:chiffres]` sont refusées
avant tout accès SQL. Aucun plafond métier arbitraire n'est ajouté.

La lecture du rappel reste limitée à son identifiant, son auteur et delivered=0.
Prepare, execute et fetch sont contrôlés. Le texte Unicode et les marqueurs
daily/weekly/urgent sont conservés ; les anciens marqueurs at sont remplacés
par un seul marqueur de date. L'UPDATE garde son SQL lié et sa condition pending.

Un succès à zéro ligne est vérifié par une nouvelle lecture avec les mêmes
conditions de propriété et d'état. Si le message est déjà exactement celui
demandé, le report est confirmé : cela conserve l'idempotence avec les drivers
qui ne comptent que les valeurs réellement changées. Sinon, aucun faux succès
n'est annoncé et aucune ligne livrée ou annulée n'est réactivée. Une erreur de
confirmation produit le message d'erreur existant, sans annoncer un succès.

La commande, son message de succès, les façades historiques, le caractère
privé/public et les autres opérations communautaires restent inchangés.

## Validation

Le cas existant `378_remindsnooze_note_hash_safety.t` reçoit huit groupes natifs
et le contrôle du processus enfant. Aucun nouveau fichier de cas n'est ajouté :
le catalogue reste à 1 158 cas. Une fixture DBI/SQLite à horloge déterministe
exécute les vrais handlers CommunityState, UserCommands et Mediabot.

Les essais couvrent les délais valides/invalides, dépassements, propriété,
arguments, les courses d'état, les modes RaiseError 0 et 1, les erreurs SQL,
l'idempotence à zéro ligne et les échecs de confirmation. Un trigger SQLite
qui ignore une mise à jour identique fournit un vrai résultat à zéro ligne.
Les courses changent réellement les lignes avant l'UPDATE. Des erreurs de
préparation utilisent une table absente ; les refus execute/fetch utilisent
les hooks d'erreur DBI. Les marqueurs récurrents et la livraison effective
avant/à l'échéance sont exercés avec le vrai livreur.

Le SQL de snooze est portable et n'est pas traduit par la fixture. Ces tests
isolés ne constituent pas une intégration MariaDB réelle et ne contactent
aucune base du bot. La qualification du paquet détaille les suites complètes
sur référence et candidat ainsi que les limites locales observées.

L'installateur garde les empreintes préalables, sauvegardes, octets, modes,
absences, suite complète sans filtre et rollback des seuls fichiers installés
par la tentative. Aucun redémarrage, commit ou push n'est automatique.
