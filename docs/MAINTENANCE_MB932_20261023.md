# MB932 — Achievements : fusion et transactions fiables

Base : `snap_mediabot_v3_teuk_20261023_181802.zip`, VERSION
`3.6dev-20261023_161250`. Aucun changement de schéma ou de migration.

## Bugs reproduits

La revue générale a identifié trois opérations à plusieurs écritures dans
`Mediabot::Achievements` : fusion de profils, import du JSON historique et remise
à zéro des acquis horaires lors d'un changement de fuseau.

La connexion de production utilise `RaiseError => 0`. La fusion et l'import ne
vérifiaient pas tous les retours SQL et localisaient `AutoCommit`. Un retour faux
pouvait donc être suivi de suppressions ou de l'archivage du JSON, et une exception
pouvait restaurer AutoCommit avant le rollback. Le reset ignorait les retours de
début et de validation de transaction. Ces chemins pouvaient aussi terminer une
transaction appartenant à leur appelant.

Un autre défaut apparaît même lors d'une fusion réussie : l'alias copié conserve
son triplet unique `(canal, nick, userhost)`. La branche de conflit actualisait ses
dates sans transférer son profil, puis la suppression des anciens alias l'effaçait.

## Correction

Les trois opérations partagent un encadrement transactionnel privé. Il exige
AutoCommit à l'entrée, vérifie begin/commit et tente le rollback uniquement après
un début réussi. Il ne localise jamais AutoCommit. Les erreurs des helpers SQL
imbriqués deviennent des exceptions dans la seule portée des écritures ; le mode
RaiseError initial est restauré. Les écritures principales vérifient également
leurs retours, y compris le succès DBI `0E0` sans ligne modifiée.

La fusion transfère désormais le propriétaire de l'alias dans la branche de
conflit avant de supprimer le profil fusionné. Elle conserve la plus ancienne
date de déblocage, la progression maximale et les dates d'observation des alias.
Un échec garde le retour historique du profil initial et un diagnostic.

L'import ne considère plus une création de profil manquée comme un enregistrement
à ignorer. En cas d'échec il conserve le fichier JSON actif et recharge les caches
après la tentative de rollback. Les archives historiques restent intactes.
L'archivage du fichier actif suit uniquement un commit réussi. Le reset ne purge
ses miroirs et ses travaux en attente qu'après validation de la transaction.

Les seuils, règles d'identité, autres achievements, annonces IRC, import min/max,
sélection des archives et fallback JSON gardent leur fonctionnement existant.
Une transaction extérieure est refusée avant toute écriture ; son propriétaire
reste responsable de sa validation ou de son annulation.

## Validation et limites

Le cas existant `826_mb646_achievements_db_identity.t` reçoit onze groupes de
régression et un contrôle du processus enfant, sans nouveau fichier de cas dans
le catalogue. La fixture utilise DBI/SQLite réels, des triggers, l'autoriseur SQL,
des contraintes différées à la validation et une seconde connexion observatrice.
Un refus de begin est injecté via l'API d'erreur DBI. Les modes RaiseError 0 et 1,
les copies/suppressions, erreurs de préparation, commit refusé, transaction
extérieure, création de profil/alias, caches, JSON et réimport d'archive sont
exercés. Le test de reset conserve aussi son succès à zéro ligne.

SQLite adapte uniquement les syntaxes MySQL DELETE JOIN, UPSERT et fonctions de
date. Il ne constitue pas un test d'intégration MariaDB. Aucun test ne contacte
une base réelle du bot. La qualification du paquet indique les résultats de la
suite entière sur la référence et le candidat, avec leurs limites locales.

Le paquet vérifie les empreintes avant toute installation, conserve octets,
modes et absences, lance la suite entière sans filtre et restaure les fichiers
de la tentative si un contrôle échoue. Il ne redémarre pas le bot.
