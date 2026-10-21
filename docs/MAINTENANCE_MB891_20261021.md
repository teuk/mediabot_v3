# MB891 — Module dédié à Instagram

## Périmètre

Les sept fonctions Instagram de `Mediabot::External::URL` sont regroupées
dans `Mediabot::External::Instagram` : identification des liens, nettoyage et
lecture des métadonnées, analyse des compteurs, récupération HTTP, composition
du texte et gestion du cache/worker. `URL.pm` passe de 1 457 à 1 099 lignes.

Le routeur conserve ses décisions et ses 18 corps de fonctions restants sont
identiques. La façade `Mediabot::External` importe le gestionnaire depuis son
propriétaire. Les sept noms historiques restent disponibles dans `URL` ; sa
liste de 17 exports optionnels et les 33 exports par défaut de la façade
restent identiques.

## Compatibilité

Les corps déplacés ne changent que par l'ajout d'un `require` différé et la
qualification des appels vers les symboles historiques de `URL`. Cela garde
les remplacements à l'exécution des helpers Instagram, du décodeur HTML et de
la clé de cache. Le chargement du module dédié seul ne charge pas le routeur
ni les fournisseurs IA ; le premier appel dépendant de `URL` le charge ensuite.
La fabrique HTTP de la façade et les helpers IRC restent des dépendances à
l'exécution, comme avant.

Sont conservés :

- les types de liens et les priorités des métadonnées ;
- le traitement des pages génériques de connexion et de Story ;
- le badge rose, les codes couleur et le RESET avant le texte ;
- l'appel historique à `truncate_utf8` avec 300 et le suffixe `…` ;
- le cache de 600 secondes et l'identité sensible à la casse du chemin ;
- la coalescence des requêtes en attente et la destination du demandeur initial ;
- le GET de 4 secondes, la limite HTTP de 1 Mio, l'agent crawler et `en-US` ;
- le worker de 6 secondes, ses grâces et sa limite de sortie de 16 Kio ;
- l'adaptateur synchrone en l'absence de boucle, les erreurs et le rappel unique ;
- l'absence de navigateur dans le traitement Instagram.

Aucune modification du schéma SQL, des requêtes SQL, de la configuration, du
runner de tests ou des services. Aucun redémarrage automatique.

## Vérification

Quatre fichiers de tests existants pointent désormais vers le bon propriétaire.
Le cas Instagram existant ajoute sept assertions : trois ordres de chargement
avec vérification des alias, deux surcharges de helpers et deux parcours de
récupération/cache (synchrone et worker) conservant Unicode et livraison unique.
Aucun nouveau fichier de cas numéroté.

Les contrôles ciblés incluent aussi les workers natifs et le cache existants de
MB864, les autres fournisseurs et les frontières URL. La comparaison externe
avant/après porte sur les fonctions réelles, les octets et indicateurs UTF-8,
les sorties IRC, options HTTP, journaux, états de cache et erreurs. Les détails
et limites de qualification sont livrés dans `QUALIFICATION.md` du paquet.

La suite complète locale présente déjà avant ce changement un échec MB786 du
répétiteur de mise à jour. L'installateur n'accepte aucune exception : la suite
complète et les deux audits doivent réussir sur la machine cible.
