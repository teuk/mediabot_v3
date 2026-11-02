# MB1077 — Charger un rôle confirmé, sans conserver les anciens droits

Base : snap_mediabot_v3_teuk_20261102_171926.zip.
VERSION : 3.8dev-20261102_161724. Les 392 chemins précédemment qualifiés
correspondent à MB1076 final ; tous les correctifs antérieurs sont conservés.

## Défaut

User::load_level gardait level/level_desc si la lecture suivante échouait ou
si le rôle n'existait plus. Un objet précédemment Owner pouvait donc continuer
à répondre positivement à has_level après un refresh raté. Une ligne retournée
avec un err DBI actif était aussi publiée sans confirmation, et RaiseError
pouvait échapper à la méthode avant le cleanup.

## Correction

Les deux champs de rôle sont retirés avant la lecture. Le niveau et sa
description ne sont publiés qu'après fetch réussi et err vide, puis nettoyage
du statement. Préparation, exécution et fetch sont protégés ensemble ; les
échecs retournent 0 avec un avertissement limité à l'étape fixe. Les détails
bruts DBI/SQL ne sont pas interpolés dans ce diagnostic.

L'absence de résultat, de DBH ou d'id de rôle retourne également 0, sans garder
les anciens droits et sans avertissement SQL pour une absence normale.
Un read réussi retourne 1. Le résultat est décidé avant finish, qui peut
modifier err. Le cleanup est tenté même après RaiseError ; son exception ne
peut ni ressusciter un read échoué, ni effacer un read déjà confirmé.

Seuls les champs de rôle sont invalidés : identité, authentification, id du
rôle, mot de passe et hostmasks ne changent pas. La méthode ne recharge pas
les données USER ni ne révoque une session à distance. Elle conserve sa requête
paramétrée par id_user_level et le choix DBH explicite/préchargé. Une lecture
ultérieure réussie restaure le rôle courant, y compris après un déclassement.
Le reste de User.pm, dont create, autologin et has_level, est inchangé.

## Tests natifs

Le cas 70 existant utilise le vrai User et SQLite/DBI. Les erreurs sont injectées
avec un RootClass qui délègue requêtes, lignes, err et RaiseError au driver.
Cinq assertions couvrent : les quatre rôles, zéro, bind et deux DBH ; prepare,
execute, fetch vide et ligne retournée avec err, avec RaiseError 0/1 ; rôle
supprimé et prérequis absents ; échec puis récupération du même objet avec rôle
User ; état sans autorité pendant finish, erreur de cleanup et priorité de la
lecture confirmée. L'identité et l'authentification restent vérifiées.

Les quatre anciens pins textuels du reader sont remplacés par ces scénarios.
Les cinq labels prepare de create sont regroupés en un contrôle, et les cinq
labels execute en un autre, sans retirer de condition. Les autres contrats de
create sont conservés. 13 assertions contre 20 : sept de moins, aucun nouveau
fichier de test ni attente. QUALIFICATION.md indique les mesures et limites.

## Exploitation

Pas de schéma, données persistantes, dépendance ou configuration à modifier.
VERSION, README racine, commit.sh privé, runner/ETA, radio, YouTube, logger
MB1076, minuteurs MB1075 et corrections antérieures sont conservés.

Contenus exacts avant/après et anciens changements qualifiés en attente
vérifiés. Full visible --progress/ETA sans redirection, audits, inventaire et
whitespace avant staging/restart. Ensuite dev seul, nouveau PID stable dix
secondes, commit.sh natif interactif --skip-preflight et VERSION 3.8dev
automatique. Un PID stable ne prouve pas la reconnexion IRC.
