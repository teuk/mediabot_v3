# MB1073 — Conserver les badwords confirmés en cas de panne de lecture

## Défaut

botPrivmsg et botAction avaient chacun leur lecture BADWORDS et leur cache.
Après expiration des 300 secondes, une erreur prepare/execute remplaçait un
cache valide par une liste vide datée comme récente. Une erreur fetch pouvait
publier une liste partielle sans consulter err. Avec RaiseError, la lecture
pouvait aussi lever une exception hors de son appelant.

Résultat : un mot interdit par les dernières règles confirmées pouvait sortir
sur IRC pendant cinq minutes après un rafraîchissement raté. Un échec du premier
chargement était lui aussi mis en cache et empêchait une nouvelle lecture.

## Correction et politique

Un helper privé de IRC::Sender réalise maintenant la lecture commune aux
messages et ACTION. Les requêtes et le binding du salon restent identiques.
Seule une lecture entièrement réussie publie ts/words. L'état est décidé avant
finish(), car le nettoyage peut effacer err. Les exceptions DBI sont contenues ;
le handle est fini sur les sorties succès/erreur où il existe.

Après échec, conserver le cache confirmé et son âge ; la prochaine émission
retente la lecture. Le diagnostic reste borné, sans texte brut d'exception SQL,
et le compteur d'erreurs DB est incrémenté. Une vraie liste vide est un succès
et remplace bien les anciennes règles. Sans aucun cache confirmé, conserver la
politique historique diagnostic puis émission, sans enregistrer la panne comme
une liste vide fraîche. Il ne s'agit pas d'un nouveau blocage général sur panne.

Le matching littéral insensible à la casse, les clés de cache, TTL et
invalidations, NoColors/AntiFlood, les sorties privées et NOTICE, la sanitation,
le découpage UTF-8, les enveloppes CTCP ACTION et les règles de logs/historique
restent inchangés. Aucun schéma SQL, dépendance ou configuration ne change.

## Vérifications

Le cas 1306 passe de 137 à 128 assertions. Des checks de rejet liés sont regroupés
sans enlever leurs conditions. Le fixture historique expose err=0 pour son
succès ; les nouveaux scénarios utilisent SQLite et les vraies erreurs DBI.
Le RootClass délègue SQL/execute/fetch à SQLite et injecte seulement les pannes.

Pour PRIVMSG et ACTION, avec et sans RaiseError : prepare, execute, fetch initial
et fetch après une ligne. Vérifier absence d'exception, de message/historique/LIVE
sur mot retenu par l'ancien cache, identité/contenu/âge du cache préservés,
compteur d'erreur, nettoyage et absence de détail SQL privé dans les logs.
Le même scénario rétablit ensuite la DB : les nouveaux mots sont filtrés dès
l'émission suivante et les anciennes règles peuvent effectivement disparaître.

Les résultats vides confirmés sont mis en cache et réutilisés ; les règles d'un
autre salon ne sont pas importées. Sans cache, un fetch raté garde l'émission
historique mais ne masque pas la reprise suivante. Aucun nouveau fichier de
test ni attente artificielle ; neuf assertions de moins au total.

Les résultats locaux et les limites de l'environnement figurent dans le
QUALIFICATION.md du paquet. La full reste obligatoire et visible --progress/ETA
sur teuk, puis sécurité/startup/inventaire et diff --check. Après réussite
seulement : staging qualifié, restart du dev seul, nouveau PID stable dix
secondes et commit.sh installé/interactif, VERSION 3.8dev automatique.
Les changements précédemment qualifiés en attente sont conservés. Pas de
modification du README racine, de radio/YouTube ou d'un service de production.
Le contrôle de PID ne prouve pas la reconnexion IRC.
