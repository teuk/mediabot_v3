# MB898 — Contrôles de version distante dans Version::Remote

Base : snapshot `snap_mediabot_v3_teuk_20261022_001442.zip`, après MB897.

## Frontière du module

`Mediabot::Version::Remote` possède les sept fonctions de sélection des sources,
configuration des délais, récupération HTTP, contrôle synchrone et adaptation au
worker partagé : `_remote_version_urls`, `_remote_version_timeout`,
`_remote_version_worker_timeout`, `fetch_remote_version`, `getVersion`,
`_version_asyncworker_reason` et `getVersion_async`.

Helpers conserve les sept points d'entrée historiques et ses exports par défaut.
Ses 93 autres corps de fonctions sont identiques. La résolution du fichier
VERSION local, son cache, `getLocalVersion`, `versionCheck`, les notifications et
les décisions de mise à jour restent chez leurs propriétaires existants. Le
formateur pur `Version::Format` reste le propriétaire de la grammaire et de la
comparaison de versions. `AsyncWorker` continue à posséder le cycle des processus.

La liste par défaut des deux URL a une seule définition, dans Remote. La liste
historique mutable `@Mediabot::Helpers::VERSION_URLS` reste initialisée avec ces
valeurs et consultée quand Helpers est chargé, y compris lorsqu'elle est vide.
Les autres hooks Helpers sont résolus au moment de chaque appel interne concerné.
Les sept exports de Remote sont optionnels ; aucun n'est importé par défaut.

Charger Remote et lire ses paramètres ne déclenche ni chargement de Helpers,
connexion HTTP, lecture de VERSION local ni accès à la base. Les opérations qui
ont besoin de l'identité locale réutilisent les helpers existants ; la requête
HTTP réutilise le client commun de `Mediabot::External` à son point d'appel.

## Contrats conservés

- Une URL configurée est un remplacement complet des deux sources par défaut.
  Un override HTTP explicite reste utilisable sans support HTTPS.
- Le délai par URL garde son défaut de 8 secondes et son plafond de 30 secondes.
  Le budget worker couvre toutes les sources, ajoute une seconde et reste borné
  à 65 secondes. Les options explicites conservent leurs règles actuelles.
- Le client HTTP conserve agent, taille maximale de 64 Kio et politique TLS
  commune. Le corps doit toujours être une version valide, d'au plus 256
  caractères, après les mêmes nettoyages. Les raisons d'échec restent transmises.
- Le chemin sans boucle reste synchrone ; le chemin avec boucle passe toujours
  par AsyncWorker, avec les mêmes délais de terminaison et limite de 1 024 octets.
- Le callback conserve ses trois arguments et sa protection contre les doubles
  appels. Les erreurs du fils restent bornées ; son logger muet garde également
  son nom historique `Mediabot::Helpers::_SilentLogger`.
- La commande version répond d'abord avec l'identité locale. Aucun contrôle de
  version distant n'est ajouté au démarrage, à une reconnexion ou à un chargement.

## Validation

Dix cas existants suivent le nouveau propriétaire de l'implémentation, tout en
conservant leurs appels fonctionnels au travers de Helpers. Six assertions sont
ajoutées au cas 834 existant : trois ordres de chargement en interpréteurs frais,
liste d'URL mutable, hooks HTTP et parseur, hooks de contrôle synchrone, hooks de
worker, logger muet et callback unique. Aucun nouveau cas numéroté n'est créé.

Les comparaisons de comportement avant/après, essais natifs de worker, résultats
de suite complète et limites de l'environnement sont consignés dans
QUALIFICATION.md du paquet. L'installation serveur exige toute la suite sans
filtre, l'audit de sécurité et le contrôle d'intégrité de démarrage.

Aucun changement du schéma SQL, des paramètres privés, de VERSION, des services,
du mécanisme d'update, du runner ou des outils d'audit n'est inclus.
