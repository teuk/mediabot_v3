# MB914 — Champs facultatifs Icecast et compteurs représentables

Date : 22 octobre 2026. Base : `snap_mediabot_v3_teuk_20261022_180413.zip`,
VERSION `3.6dev-20261022_160346`.

## Défauts reproduits hors plugins

Les six vues publiques d'Icecast normalisent un même instantané par appel, mais
certains champs facultatifs restaient des objets, tableaux ou booléens JSON.
Ils pouvaient être interpolés en HASH(...)/ARRAY(...), notamment un faux montage
/HASH(...) issu de server_name, ou rester des références dans le titre et le
statut. Une chaîne de 400 chiffres pouvait produire Inf dans les compteurs
normalisés d'un montage, sans être un nombre utilisable pour l'affichage.

## Correction ciblée

Le helper privé _scalar conserve les scalaires et laisse undef pour les
références. Il sert aux métadonnées globales host/admin/location/server_id et
dates, puis aux champs de montage listenurl/server_name/description/server_url,
title et dates. Un titre invalide devient vide. Les replis existants sur le nom
du serveur ou l'ancienne date ne choisissent plus une référence JSON.

_num refuse une référence avant toute conversion et renvoie zéro si la
conversion n'est pas finie. POSIX::isfinite est une dépendance Perl core.
Il n'y a pas de plafond arbitraire nouveau : les grands nombres encore finis,
décimaux, séparateurs de milliers, blancs et zéros gardent leur normalisation.
Le calcul des totaux n'est pas réécrit.

La réponse brute raw reste intacte. Les métadonnées non concernées, dont
audio_info, source_ip et user_agent, conservent leur forme. Aucune nouvelle
suppression de montage ou de source HASH ; les entrées non HASH gardent leur
filtrage historique. Le tri, le montage primaire, le repli sur le premier
montage, les URLs publiques et un seul fetch par vue ne changent pas.

## Validation

Huit critères s'ajoutent au cas 1256 : métadonnées globales structurées,
métadonnées de montage structurées, identité de montage invalide, références
numériques, conversion non finie, grands nombres finis, mélange de sources
valides/invalides et zéros scalaires. Chaque critère appelle les six méthodes
publiques avec le faux client séquentiel existant. Les données brutes restent
consultables et les bonnes métadonnées du même instantané restent utilisables.

Les nouveaux critères passent 8/8 candidat, 2/8 référence. Les 66 anciennes
assertions sont inchangées et passent dans les deux arbres. Cinq mutations sont
détectées, y compris un plafond numérique arbitraire qui casserait un cas valide.

Une sonde supplémentaire utilise un vrai serveur HTTP loopback et HTTP::Tiny :
texte structuré, compteur non fini puis réponse Unicode saine. Le candidat passe
3/3 contre 1/3 pour la référence ; trois appels font exactement trois GET vers
status-json.xsl et l'enfant serveur est collecté. Aucun service Icecast installé,
réseau extérieur, configuration privée, SQL ou sortie IRC réelle n'est utilisé.

Soixante-douze instantanés nominaux, chacun lu par les six vues publiques,
comparent 432 appels. Formes HASH/ARRAY/mélange/source absente, six profils
numériques et texte absent/zéro/Unicode sont couverts. Les résultats complets,
y compris raw et les métadonnées non concernées, ainsi que les requêtes sont
identiques entre référence et candidat, sans warning observé. Les contrôles
HTTP natifs existants du cas 1257 restent également dans le groupe ciblé.

Le groupe radio/Icecast/Liquidsoap passe 416 assertions sur 24 fichiers ; les
37 invariants et l'intégrité de démarrage passent. QUALIFICATION.md détaille les
full suites et la livraison. Toute la suite reste obligatoire sur le serveur.

Quatre chemins : trois modifications et cette note nouvelle. Les 1 156 cas sont
conservés, sans nouveau fixture ou cas numéroté. Aucun schéma de base/API, SQL de
production, plugin, configuration privée, VERSION, service, Liquidsoap, commande
métier, Partyline, runner ou audit n'est modifié. Aucun commit/push/restart automatique.
