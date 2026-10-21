# MB895 — Un lecteur partagé pour le journal des canaux

## Responsabilité extraite

`Mediabot::Helpers` mélangeait des fonctions IRC, comptes utilisateurs,
versions, anti-flood et lecture des archives. Trois fonctions cohérentes de
lecture sont maintenant implémentées dans `Mediabot::ChannelLog::Reader` :

- `channel_log_archive_table($bot)` valide le nom de base déjà configuré ;
- `channel_log_sources($bot, $scope)` sélectionne actif seul ou actif/archive ;
- `channel_log_gather($bot, $dbh, $sql, $bind, $callback, $scope)` exécute le
  modèle de requête par source et transmet les lignes au callback du demandeur.

Les fonctions sont disponibles par nom qualifié ou import explicite ; rien
n'est exporté par défaut. Le lecteur ne charge pas Helpers pour fonctionner,
ne crée pas de connexion et n'exécute rien au chargement. Le demandeur garde
le handle DB, les requêtes, les paramètres et la fusion des résultats.

Les trois noms historiques restent dans Helpers avec des wrappers. Les
consommateurs actuels (historique, commandes, service d'activité) y accèdent
sans être réécrits. Lorsque les points d'entrée Helpers sont définis, le lecteur
résout leurs surcharges de sélection d'archive/sources au moment de l'appel.
Cela conserve les extensions et fixtures existantes sans imposer Helpers aux
nouveaux consommateurs autonomes. Les 97 autres corps de fonctions et les
exports par défaut de Helpers restent identiques.

## Contrats conservés

Le journal actif est lu avant l'archive. Les requêtes utilisent les mêmes
substitutions `__CLSRC__` et paramètres ; les pourcentages des modèles SQL ne
sont pas interprétés. Le callback reçoit chaque ligne et son nom de source,
dans le même ordre, sans accumulation globale des lignes par le lecteur.

Une lecture vide reste un succès. L'échec de préparation/exécution/fin de
lecture du journal actif arrête le parcours. Une panne d'archive avant toute
ligne laisse le résultat actif exploitable et produit le même diagnostic.
Après livraison de lignes partielles de l'archive, le résultat est marqué
`tainted` et `live_ok` repasse à zéro. Les exceptions des callbacks ou de fetch,
les tentatives de finish et le traitement des diagnostics gardent leur
comportement historique. L'extraction ne les transforme pas en nouvelle
politique de récupération.

Aucun changement des requêtes des commandes, du schéma, des tables, des
index, des rétentions, de la configuration, de VERSION ou des services.
Les noms, portées, valeurs de retour, budgets IRC et rendus restent inchangés.
L'extraction n'ajoute aucune migration ou écriture SQL. Comme auparavant,
le modèle SQL est fourni par l'appelant ; cette API n'impose pas de validation
SELECT du modèle.

## Qualification

Le cas existant 765 ajoute cinq assertions : trois ordres de chargement dans
des processus Perl frais, dont une lecture autonome complète sans Helpers,
et deux scénarios de surcharges historiques. Il passe de 40 à 45 assertions.
La garde existante contre UNION ALL couvre aussi le nouveau propriétaire.
Un mutant qui contourne les surcharges est rejeté par cinq assertions, dont
les deux nouveaux scénarios de hooks.

Un probe externe compare 143 scénarios sur les vrais modules avant/après,
via les anciens points d'entrée puis directement via Reader. Les trois séries
sont identiques pour les résultats, requêtes/paramètres, ordre des callbacks,
statuts, diagnostics et avertissements. Les scénarios couvrent configuration,
scopes, succès, vide, pannes et trois lectures avec de vrais handles DBI/SQLite
en mémoire et une archive attachée. Ces tables sont uniquement des fixtures
locales. Seules les positions source et adresses de références dans les
messages sont normalisées ; ce n'est pas une preuve pour toute entrée Perl.

Voir `QUALIFICATION.md` dans le paquet pour les comptes des suites, les
limites du runtime et la répétition installation/restauration. Aucun nouveau
cas numéroté, exclusion ou cache de résultats n'est ajouté.

## Base cumulative

Le snapshot fourni `snap_mediabot_v3_teuk_20261021_215158.zip` contient MB893,
avec VERSION actualisé, mais pas le correctif MB894 déjà préparé. Ce paquet
MB895 reprend cette correction et sa note, sans supposer sa validation serveur.
Les six assertions MB894 et cinq assertions du lecteur complètent deux cas
existants ; le catalogue reste de 1 156 fichiers.
