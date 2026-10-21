# MB896 — Un propriétaire pour la grammaire des versions

## Extraction

Cinq fonctions sans entrées/sorties sont implémentées dans
`Mediabot::Version::Format` :

| Fonction | Contrat historique conservé |
| --- | --- |
| `_usable_local_version($value)` | Nettoie un scalaire non vide et rejette le marqueur Undefined ; ne valide pas à elle seule la grammaire. |
| `_version_parts($value)` | Renvoie les champs major, minor, stage, type et dev, ou undef. |
| `_compare_digit_strings($left, $right)` | Compare les longueurs puis les chaînes, avec les mêmes valeurs par défaut. |
| `_compare_mediabot_versions($left, $right)` | Classe stable/développement selon les règles Mediabot, ou renvoie undef pour un format inconnu. |
| `getDetailedVersion($self, $value)` | Garde la signature historique et le tuple major/minor/type/dev, y compris les retours en contexte scalaire. |

Les fonctions peuvent être appelées par leur nom qualifié ou importées
explicitement ; aucune n'est exportée par défaut. Ce module peut être chargé
et utilisé seul. Il ne lit pas VERSION, ne crée pas de connexion et ne charge
pas Helpers, HTTP ou DBI pour effectuer ses calculs.

Helpers garde les cinq points d'entrée avec des wrappers. Les consommateurs
existants passent ainsi par le nouveau propriétaire sans réécriture des
commandes. Quand les fonctions Helpers existent, le module résout au moment
de l'appel leurs normaliseur, parseur et comparateur de chiffres. Les anciens
hooks restent donc effectifs, y compris si un hook de parsing est remplacé
entre les deux opérandes d'une comparaison.

## Limites volontaires

La grammaire existante est propre à Mediabot ; elle ne devient pas une
implémentation SemVer. Aucun durcissement des formats, changement de zéros
initiaux, conversion supplémentaire ou normalisation Unicode n'est ajouté.
Les règles de précédence restent major, minor, stable/développement puis
numéro du build de développement. Le comportement des scalaires, tuples,
flags UTF-8, avertissements et erreurs est conservé.

Les 95 autres corps de fonctions de Helpers restent identiques. La résolution
du chemin de VERSION à partir de Helpers est laissée en place : déplacer ce
code avec les fonctions pures aurait pu changer la racine utilisée. Le cache
local, le repli sur l'identité en mémoire, les requêtes distantes, les délais,
workers, notifications et décisions d'update restent aussi en place.

Aucun changement du schéma, des requêtes SQL, des tables, de la configuration,
de VERSION, des services ou des outils d'audit. Aucun test ni contrôle complet
n'est exclu. Cette extraction ne revendique pas d'accélération de la suite.

## Vérification

Le cas existant 607 ajoute six assertions : trois ordres de chargement dans
des processus Perl frais, puis trois contrats de hooks. Il passe de 19 à 25
assertions. Sa garde de présence du comparateur vise maintenant le propriétaire
canonique. Retirer les résolutions historiques provoque trois échecs, tandis
que le candidat passe à 25/25. Aucun nouveau cas numéroté.

Un probe externe compare les vrais modules, sans recopier les algorithmes,
sur 2 835 scénarios : 51 entrées d'analyse, leurs 2 601 paires de comparaison,
169 paires de chaînes de chiffres, six hooks, sept réponses distantes locales
et une lecture de VERSION depuis un répertoire étranger. Tous sont identiques
entre la référence, les wrappers et l'API canonique.

Les contrôles couvrent valeurs absentes, références, formats valides/invalides,
stable/développement, grands builds, zéros initiaux, Unicode brut/décodé,
contextes scalaire/liste, erreurs et surcharges. Les intégrations locales
comparent aussi les résultats, options HTTP, cache et diagnostics sans réseau
public. Seuls les chemins des deux arbres de qualification, positions source
et adresses de références dans les messages sont normalisés.

Cette comparaison ne prouve pas l'équivalence pour toute valeur Perl ou
extension externe. Voir QUALIFICATION.md dans le paquet pour les suites
complètes, limites du runtime et répétition installation/restauration.

Base : snapshot `snap_mediabot_v3_teuk_20261021_221901.zip`, après MB895 validé
sur le serveur. Le catalogue reste de 1 156 fichiers de cas.
