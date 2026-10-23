# MB919 — Karma : annonces fiables et blocage anti-brigade effectif

Date : 2026-10-23. Base : `snap_mediabot_v3_teuk_20261023_100514.zip`.

## Deux défauts reproduits dans processKarma

1. Le message privé `[karmawatch] ... received ++/-- karma` partait avant
   `prepare/execute` de l'écriture KARMA. Une préparation refusée ou une
   exécution échouée laissait donc annoncer un vote absent de la base.
2. L'anti-brigade détectait le sixième voteur distinct sur une cible en
   30 secondes, affichait son avertissement et incrémentait son compteur
   de blocages, puis enregistrait malgré tout le vote. En Perl, le `next`
   sans label s'appliquait au bloc nu contenant cette protection, et non
   à la boucle extérieure qui parcourt les votes du message.

## Correction bornée à la fonction existante

- Le message aux abonnés suit désormais la réussite de l'écriture et le
  `finish` de son statement. Il précède toujours l'annonce publique du score.
- Un statement créé mais refusé à l'exécution est terminé avant de passer
  à la cible suivante. Une préparation échouée n'est pas déréférencée.
- La boucle de votes reçoit un label `KARMA_VOTE` ; la branche anti-brigade
  utilise `next KARMA_VOTE`. Une cible suivante du même message reste traitée.
- Le seuil reste strictement supérieur à cinq voteurs distincts en 30 secondes.
  L'avertissement reste émis une seule fois pendant le blocage ; l'expiration
  et la remise à zéro de cet avertissement conservent leurs règles existantes.

Le cooldown par voteur/cible est toujours réservé avant l'écriture. Le compteur
historique `mediabot_karma_votes_total` garde son emplacement : cette correction
ne redéfinit pas son comportement sur une tentative SQL refusée. Un vote bloqué
par l'anti-brigade ne doit en revanche plus atteindre ce compteur ni l'écriture.

Une écriture réussie est annoncée même si la lecture suivante du score échoue :
le vote existe déjà. On ne subordonne pas sa notification à cette lecture
facultative. Aucun retry ou nouvelle transaction n'est introduit. La connexion
normale du bot reste en AutoCommit. Pour un appelant qui gérerait sa propre
transaction, la réussite d'execute ne promet pas un commit ultérieur.

Les requêtes, binds, retours des fonctions, couleurs, destinations et textes
nominaux, prise en compte de la présence, rejet de l'auto-vote, limite de trois
cibles par message, historique, droits et hooks de succès sont conservés hors
corrections décrites. Aucun changement de schéma, migration, fichier SQL de
production, configuration privée, VERSION, module IRC partagé ou autre sous-système.

## Régression et comparaison

Le cas 670 existant conserve ses sept critères et reçoit neuf assertions
regroupées : **16/16** avec la correction, **8/16** contre le snapshot initial.
Il exécute les vraies méthodes `processKarma` et `mbKarma_ctx` dans un processus
Perl séparé, sur un vrai handle DBI/SQLite privé. Un pont réservé au test traduit
l'upsert MariaDB et l'INSERT IGNORE/NOW de l'historique pour SQLite. Les refus
viennent d'une table absente à la préparation ou d'un trigger SQLite refusant
l'INSERT. Les sorties IRC, métriques et contexte de commande sont contrôlés.
Aucun serveur MariaDB ou IRC réel n'est contacté.

Les cas couvrent les deux entrées et les deux signes, les erreurs avant et après
l'écriture, le nettoyage, le cooldown après échec et la reprise après son délai,
une première cible refusée suivie d'une seconde acceptée, les cinquième/sixième/
septième voteurs, l'avertissement unique et l'expiration de la fenêtre anti-brigade.
Les horloges de production ne sont pas changées : les sondes font vieillir leurs
états privés pour déclencher l'expiration sans attente réelle.

En qualification séparée, **96 votes nominaux** gardent retours, messages exacts,
SQL/binds, lignes enregistrées, historique sans son horodatage, métriques et
appels d'achievements identiques entre source et candidat. Variations : deux
entrées, deux signes, trois scores initiaux, abonné présent/absent, achievements
présents/absents et voteur ASCII/Unicode. Les observations SQL au moment précis
de la notification sont volontairement exclues de cette comparaison : leur
nouvel ordre constitue la correction.

Quatre autres scénarios natifs conservent leurs sorties et écritures : auto-vote,
cible absente, répétition immédiate et plafond de trois cibles. Le cinquième
scénario reproduit puis corrige l'anti-brigade : six votes enregistrés avant,
cinq après. Six mutations indépendantes des corrections sont toutes détectées
par les nouveaux critères, les sept anciens restant valides.

Aucun nouveau module, fixture partagé ou cas numéroté : les **1 156 cas** restent.
Les détails des suites complètes et les limites locales figurent dans le
`QUALIFICATION.md` du paquet ; sa validation par défaut exige toujours la suite
entière sans filtre, l'audit et l'intégrité de démarrage.
