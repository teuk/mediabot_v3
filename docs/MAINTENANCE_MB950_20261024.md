# MB950 — Clôture documentaire de la roadmap 3.6dev

Date : 24 octobre 2026.
Base : MB949, commit serveur poussé `b010abe`, VERSION
`3.6dev-20261024_164906` ; snapshot `snap_mediabot_v3_teuk_20261024_185553.zip`.

## Résultat

Le cycle MB938–MB949 est clos. Les cinq axes livrés et leurs références sont
rassemblés dans ROADMAP_3.6DEV.md. MB949 y passe de candidat à installé,
validé et poussé, selon les retours serveur fournis par l'opérateur.

Les trois vérifications terrain sans résultat concluant sont conservées dans
RELEASE_ACCEPTANCE_3.6DEV.md, avec leur état et le critère de fin. Elles restent
des conditions des décisions d'exploitation concernées ; elles ne sont pas
déclarées réussies. La stable publiée reste 3.5.

README et CHANGELOG rendent cette clôture visible. Les écritures mbweb,
l'effacement Hailo sélectif et les autres orientations restent hors périmètre.

## Portée et contrôle

Cinq fichiers Markdown uniquement. Aucun code exécutable du dépôt, test,
dépendance, schéma, configuration privée ou service n'est modifié.
VERSION reste géré par commit.sh.

Le paquet vérifie ses hashes, les préconditions des cinq chemins et leurs liens
documentaires locaux. L'installateur existant conserve ses neuf tests et son
retour des octets, modes et absences. Aucun nouveau test applicatif n'est ajouté.
La suite applicative complète n'est pas relancée pour ce lot documentaire.

Dernier résultat applicatif réel, fourni sur teuk pour MB949 :
31 105/31 105 assertions, 1 166 fichiers ; inventaire conforme, sécurité GO/37,
intégrité de démarrage OK. Ce résultat appartient à MB949, pas à une nouvelle
exécution MB950.

Le paquet ne redémarre aucun service, ne crée aucun utilisateur et n'exécute
aucune commande Ansible. Une installation MB950 sur teuk ne sera confirmée
qu'après le retour opérateur ; cette note décrit le lot préparé.
