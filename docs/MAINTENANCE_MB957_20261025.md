# MB957 — Horoscope et vues des achievements

Date : 2026-10-25. Source : `snap_mediabot_v3_teuk_20261025_131407.zip`,
VERSION `3.6dev-20261025_080920`. Les hashes avant/après fixent les chemins livrés.

## Organisation

`Users/Horoscope.pm` devient propriétaire de la commande, des quatre helpers
zodiacaux et du tableau canonique des slugs. `Users/AchievementView.pm` contient
la commande achievements et ses trois formateurs. Les neuf corps extraits et
les 32 autres fonctions de UserCommands restent identiques. La liste d'exports
publique reste identique ; les anciens noms de helpers et le hash des signes
restent accessibles par le même package. UserCommands passe de 3 332 à 2 686 lignes.

Les transports, la validation de calendrier et la progression persistante
conservent leurs hooks tardifs. SocialHistory conserve son accès au formateur
d'objectif par la façade. Aucun cycle de chargement n'est ajouté.

## Contrats

L'horoscope conserve Games sur canal, l'accès privé, le choix explicite du signe
avant le pseudo, les anniversaires et leur validation, les langues, le générateur
local déterministe sans effet sur le RNG global, le repli fournisseur, les deux
lignes compactes, les métriques et les compteurs d'achievement. L'API externe
et le modèle de stockage ne sont pas déplacés.

Les achievements conservent le catalogue privé, les notices de progression,
les classements, la portée canal/cross-canal et la visibilité des secrets.
Les vues ne lisent pas les hashes internes de stockage. Les cas historiques
suivent les propriétaires réels sans abaisser leurs assertions.

Un nouveau cas teste trois ordres de chargement dans des interpréteurs frais :
API native et historique, table partagée, refus Games avant SQL/fournisseur,
hooks remplacés après chargement, calendrier, RNG global, progression persistante,
routes privées et budget UTF-8. La qualification du paquet précise les résultats
locaux et leurs limites. Les SQL, sorties et hooks sont comparés avant/après
sur des fixtures hors ligne ; aucune recette IRC réelle n'est revendiquée.

## Déploiement

Le paquet externe s'applique sous mediabot sur teuk. Il vérifie les préimages,
sauvegarde les fichiers et impose syntaxe, inventaire, tests ciblés, suite entière,
sécurité et intégrité avant le redémarrage explicitement demandé du dev.
Seul `mediabot@dev.service` est autorisé. Son PID doit correspondre au compte
mediabot, au répertoire de dev et à `mediabot.conf` avant puis après redémarrage.
Un échec de déploiement tente la restauration du lot et la relance du dev ;
une récupération non confirmée est signalée comme telle. Le commit/push est
séparé et vérifie le résultat du déploiement ainsi que les changements Git.

Aucune configuration, donnée, dépendance, base, migration, unité ou instance
de production n'est modifiée par ce lot. VERSION reste géré par commit.sh.

Navigation : [développement](DEVELOPING.md),
[inventaire](generated/COMMAND_INVENTORY.md).
