# MB892 — Module dédié aux métadonnées Facebook

## Périmètre

`Mediabot::External::Facebook` devient le propriétaire de quatre fonctions :
normalisation des URL, lecture du titre HTML/DOM, libellé de repli issu de l'URL
et gestionnaire HTTP/Chromium/cache/IRC. Le routeur reste dans `URL.pm`, qui
passe de 1 099 à 827 lignes. Ses 14 corps de fonctions restants sont identiques.

La façade `Mediabot::External` importe les quatre fonctions depuis le nouveau
propriétaire. Leurs quatre alias historiques dans `URL` restent disponibles.
Les 17 exports optionnels de URL et les 33 exports par défaut de la façade ne
changent pas. Le module seul ne charge pas URL ni les fournisseurs IA ; ses
fonctions dépendantes chargent URL à l'appel.

## Contrats conservés

Les corps déplacés ne changent que par deux `require` différés et la
qualification des appels vers les symboles historiques de URL. Les surcharges
du normaliseur, parseur de titre, repli, décodeurs, navigateur et identité de
cache restent donc actives à l'exécution. La fabrique HTTP de la façade et les
helpers IRC conservent leurs points d'appel.

Le GET garde 8 secondes, 1 Mio, son agent crawler et `en-US`. Un titre HTTP
utile évite Chromium. Un Reel sans titre utile garde son repli immédiat sans
navigateur. Les autres liens conservent le repli Chromium, les paramètres de
configuration, leurs bornes et `fr-FR`. Le repli par URL intervient ensuite.
Les exceptions gardent leur propagation existante.

Le badge blanc sur bleu, les crochets noirs et le RESET sont identiques. La
description conserve son filtrage, la détection de doublons et sa coupe de
150 caractères (147 suivis de `...` si nécessaire). Le texte final conserve sa
coupe historique à 300 caractères. Ces règles ne sont pas converties en budget
d'octets : cela changerait les sorties existantes. Le transport IRC garde ses
propres protections déjà en place.

Le cache garde 600 secondes, l'identité normalisée sensible à la casse des
ressources et le rendu mémorisé. La relecture utilise toujours le demandeur et
le canal actuels. Les décisions d'admission restent celles du routeur existant.

Aucun changement SQL, schéma, migration, configuration privée, VERSION, runner
ou service. Aucun commit ni redémarrage automatique dans l'installateur.

## Vérification

Cinq cas existants ajustent leurs lectures de source au nouveau propriétaire.
Le cas Facebook/Reel existant ajoute cinq assertions : trois ordres de
chargement avec égalité des alias, une surcharge du décodeur HTML et un parcours
complet de surcharges avec récupération, navigateur, repli et relecture du
cache. Le contrôle de structure ajoute automatiquement trois assertions pour
le nouveau module ; aucun nouveau cas numéroté n'est ajouté.

Le groupe ciblé vérifie aussi les couleurs, entités HTML, compteurs, attributs
de métadonnées, repli de tous les types de liens, caches et routages des autres
fournisseurs. La comparaison avant/après utilise les vrais modules dans deux
processus avec des réponses locales. Voir `QUALIFICATION.md` dans le paquet
pour les résultats et limites.

Le runtime local présente avant cette refactorisation l'échec MB786 connu du
répétiteur de mise à jour. L'installateur n'exclut aucun test et exige une suite
complète verte sur le serveur, suivie des audits sécurité et démarrage.
