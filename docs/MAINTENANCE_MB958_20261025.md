# MB958 — Vues publiques du canal : radar, capacités et observatoire

Date : 2026-10-25. Base : état MB957 préparé depuis
`snap_mediabot_v3_teuk_20261025_131407.zip`. Les préimages des fichiers touchés
fixent l'état attendu ; aucun SHA de commit serveur n'est inventé. VERSION
reste géré par commit.sh et ne fait pas partie des fichiers remplacés.

## Organisation et compatibilité

`Stats/Radar.pm` possède `mbRadar_ctx`. `Diagnostics/Commands.pm` possède
`mbFeatures_ctx`, `mbObservatory_ctx` et leurs trois helpers de chanset, durée
et énergie. Les six corps extraits et les 26 autres fonctions de UserCommands
restent identiques ; la liste d'exports publique ne change pas. Les noms de
helpers historiques restent disponibles. UserCommands passe de 2 686 à
2 288 lignes. Les transports et le formateur de nombres restent tardifs.

Le radar conserve ses lectures de la table vive, le filtre public/action,
les bornes de 1 à 30 jours, les périodes, seuils, sparklines, nouveaux venus,
nicks silencieux, exclusions du bot, limites et activité karma. Les requêtes,
leurs paramètres et leurs replis restent identiques, y compris en échec SQL.
Aucune promesse nouvelle de fusion d'archives n'est introduite.

Les capacités conservent leurs huit notices privées et les états on/off,
missing et legacy default. L'observatoire conserve ses deux lignes publiques,
la dernière heure du canal demandé, les seuils d'énergie, l'uptime du processus,
les replis et la métrique par canal. Les alias du catalogue ne changent pas.

Les collecteurs Diagnostics/Channel, Activity, Plugins et Publisher, ainsi
que le lecteur mbweb et les fichiers de diagnostic déjà publiés, restent
inchangés. Ce lot n'active ni ne reconfigure un salon ou un service web.

## Qualification

Les contrôles SQL de filtre public/action et de prédicats temporels suivent
les deux nouveaux propriétaires. Les contrôles UTF-8 et d'indépendance du
stockage suivent également les vues extraites, sans réduire leurs critères.
Un nouveau cas exécute trois ordres de chargement dans des interpréteurs frais :
alias/méthodes, hooks tardifs, refus privé avant travail, routes de sortie,
scopes SQL/chansets/métriques, fenêtres historiques bornées et replis SQL.

Une comparaison hors ligne des commandes et des helpers avant/après couvre
les variantes de canal, activité, jeux de données, erreurs, objets runtime et
chansets. Le fichier QUALIFICATION.md du paquet annonce les résultats mesurés,
la suite complète et ses éventuelles limites locales sans les masquer.

## Application

Le paquet s'applique et se teste comme mediabot sur teuk. Les fichiers sont
protégés par préimages et sauvegardés. La suite complète reste obligatoire
avant le redémarrage explicite du seul `mediabot@dev.service` via sudo -n.
Le processus est lié au compte, répertoire, entrée et configuration du dev,
puis doit avoir un nouveau PID stable. Le commit/push séparé conserve le
script natif, son affichage de revue, sa confirmation et sa gestion de VERSION.

Aucun schéma, requête, dépendance, réglage privé, privilège, base de données,
unité, configuration mbweb ou instance de production ne change dans le lot.

Navigation : [développement](DEVELOPING.md),
[inventaire des commandes](generated/COMMAND_INVENTORY.md).
