# MB956 — Statistiques : phrases récurrentes et affinités

Date : 2026-10-25. Base : snapshot fourni
`snap_mediabot_v3_teuk_20261025_065936.zip`, VERSION
`3.6dev-20261025_055752`. Les hashes du paquet fixent les fichiers avant/après.

## Organisation

- `Mediabot/Stats/History.pm` devient propriétaire de `userTopSay_ctx`, en plus
  de wordcount, streak et last.
- `Mediabot/Stats/Affinity.pm` contient `mbCompat_ctx` et ses quatre hooks de
  compatibilité tardifs : sorties, journal et progression d'achievement.
- `UserCommands.pm` conserve les imports historiques et sa liste d'exports.
  Il passe de 3 730 à 3 332 lignes. Les deux corps extraits, les 41 corps
  restants et les fonctions déjà présentes dans History restent identiques.

## Contrats conservés

`topsay` conserve la connexion et le niveau Administrator requis, le canal
explicite, l'échappement des caractères `!`, `%` et `_`, le filtre public/action,
LIMIT 30, le filtrage des réponses inutiles, le gras des actions, les trois
entrées par page et les détails privés avec troncature UTF-8.

`compat` conserve son chanset Games, ses quatre dimensions et leur pondération,
les requêtes et leurs paramètres, les échecs live distincts d'un historique
vide, la fusion des heures et des mots entre vif et archive, la limite globale
des 5 000 messages par nick, les mots UTF-8 en octets, le karma du salon et
la co-présence récente sur le vif. Les compteurs, achievements, métriques et
logs conservent leurs clés et leurs hooks historiques.

Les sources historiques de dix cas sont réorientées vers les propriétaires
réels sans retirer leurs critères ni diminuer de seuil. Le cas d'échappement
`topsay` ajoute trois contrôles dans des interpréteurs frais : chargements dans
les deux ordres, alias/méthodes réels, refus avant SQL, paramètres littéraux,
pagination publique/privée, Games et progression d'achievement tardive.

Les requêtes SQL de qualification utilisent des doubles : aucune recette de
base ou connexion IRC réelle n'est revendiquée. `QUALIFICATION.md` du paquet
indique les résultats exacts du groupe ciblé, de la comparaison avant/après,
de la suite complète et les limites éventuelles de l'environnement local.

## Installation

L'installateur vérifie tous les chemins et hashes avant d'écrire. Il sauvegarde
les fichiers touchés, garde les modes existants et restaure les fichiers écrits
par sa tentative si les contrôles échouent. Une restauration explicite refuse
les fichiers modifiés depuis l'application. VERSION reste géré par commit.sh.

Aucun schéma, requête, privilège, dépendance, réglage privé, activation de
plugin, service ou procédure Ansible ne change. Aucun redémarrage n'est inclus.
Le catalogue et l'inventaire de commandes restent inchangés.

Navigation : [développement](DEVELOPING.md),
[inventaire des commandes](generated/COMMAND_INVENTORY.md).
