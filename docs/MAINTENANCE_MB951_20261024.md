# MB951 — Des modules de jeux lisibles et une entrée pour contribuer

Date : 24 octobre 2026. Base serveur : MB950 / e5931ff,
VERSION 3.6dev-20261024_170540.
Snapshot fourni : snap_mediabot_v3_teuk_20261024_192818.zip,
SHA-256 1eaa9539c3435fc9500d28bf602075b8e6e17e2b45ebd422f124b1e9b8331771.
Les cinq payloads MB950 concordent avec le snapshot.

## But et choix de périmètre

Le nouveau chapitre vise un dépôt plus facile à comprendre et à contribuer.
L'inventaire trouve 209 modules Perl ; UserCommands.pm reste le plus gros,
avec 7 885 lignes. Ce premier lot isole deux responsabilités cohérentes et
répare le parcours de contribution. Il ne prétend pas refactoriser tous les
sous-systèmes en une seule livraison et ne rouvre pas la roadmap clôturée.

## Extraction des jeux

Games/Trivia.pm reçoit le handler, l'adaptateur AsyncWorker, les réponses,
classements, reset, arrêt et scores Trivia. Games/QuoteGame.pm reçoit le jeu,
les réponses et les helpers de son timer. Onze noms restent importés dans
UserCommands ; les huit points d'entrée publics restent disponibles dans
la classe Mediabot et dans le catalogue de commandes existant.

Les corps déplacés sont identiques après normalisation des qualifications
explicites des anciens appels internes. Les sorties, progression achievements
et source synchrone gardent une résolution tardive vers leurs hooks historiques.
Les appels imbriqués fetch/reset/timer gardent également cette compatibilité.
Les nouveaux modules peuvent être chargés avant la façade sans charger celle-ci.
Ce sont des modules de domaine utilisés par le parcours de commande existant,
pas des applications indépendantes.

UserCommands.pm passe de 7 885 à 6 594 lignes : 1 291 lignes en moins, environ
16 %. Le dépôt possède maintenant 211 modules. Ni SQL, noms des commandes,
état de jeu, score, autorisation, Unicode, durée, protocole worker ou budget HTTP
ne change. Aucun nouveau framework ou registre n'est ajouté.

## Parcours développeur

README donne une entrée directe pour cloner et contribuer, puis renvoie vers
DEVELOPING.md : dépendances Perl locales, tests hors ligne et carte des sources.
L'attribution LLM est conservée sous une forme factuelle. CONTRIBUTING utilise
le runner natif au lieu de conseiller prove pour l'ensemble des anciens cas.
/local/ est ignoré pour éviter de proposer l'arbre CPAN aux commits.

Le guide distingue le travail hors ligne de ./configure, qui prépare une vraie
instance. Les commandes CPAN sont dérivées du workflow CI fourni ; ce lot ne
revendique pas une nouvelle installation réseau de ces dépendances. Les commandes
de test proposées et les syntaxes shell sont contrôlées localement.

## Vérifications de comportement

Les douze cas existants qui inspectent la localisation du code suivent les
nouveaux propriétaires. Aucun critère historique n'est supprimé ; les scénarios
natifs de jeux restent identiques. Trois ordres de chargement supplémentaires
vérifient les onze alias et les huit méthodes publiques de la vraie classe.
Aucun fichier de cas numéroté n'est ajouté : le catalogue reste à 1 166 fichiers.

Une qualification comparative réutilise les 162 scénarios natifs MB920 sur la
source et le candidat. Résultats identiques pour état, sorties et octets UTF-8,
SQL/binds, scores persistants, métriques et présence des timers. Elle utilise
DBI/SQLite et IO::Async réels, sans base ou connexion IRC existante.
Les résultats des groupes, suite entière et contrôles sont dans QUALIFICATION.md.
Les limites de l'environnement hébergé ne deviennent aucune exclusion serveur.

## Livraison

Vingt et un chemins protégés par hashes avant/après. L'installateur conserve sauvegarde,
réapplication et restauration des octets, modes et absences. Il exige syntaxes,
groupe ciblé, inventaire, suite complète sans filtre, sécurité et intégrité sur
le serveur. Un échec restaure les seuls fichiers écrits par la tentative.

Aucun schéma, dépendance verrouillée, configuration privée, activation, service,
compte ou déploiement de production n'est modifié. VERSION reste géré par
commit.sh. Aucun redémarrage ou commit n'est automatique. Ce lot prépare une
base plus accueillante ; il ne promet pas un nombre de clones GitHub.
