# MB916 — Lire une seule fois l'UTF-8 des métadonnées yt-dlp

Date : 22 octobre 2026. Base : `snap_mediabot_v3_teuk_20261022_190104.zip`,
VERSION `3.6dev-20261022_165933`.

## Défaut reproduit

_metadata_from_info_json ouvrait le sidecar yt-dlp avec :encoding(UTF-8), puis
transmettait les caractères à JSON::PP::decode_json, qui attend des octets UTF-8.
Une métadonnée valide contenant Björk, du japonais ou un emoji était rejetée.
La méthode retournait alors identifiant vide, artiste Unknown et titre vide.
_finish_download utilisait ensuite ses replis stdout/nom de fichier ; les
métadonnées présentes dans le sidecar n'arrivaient pas intactes au catalogue.

## Correction

Une ligne de production change : le sidecar est ouvert avec :raw. Le parseur
JSON::PP existant décode ainsi les octets UTF-8 une seule fois. Le backend JSON,
les trois valeurs retournées, la priorité artist/creator/uploader/channel,
les trims et les replis ne sont pas réécrits. Aucun helper, module ou dépendance
de production n'est ajouté. Un document UTF-8 invalide atteint le rejet existant
du parseur, sans warning du décodage PerlIO préalable.

Les fichiers audio et sidecars ne sont pas modifiés par la lecture. Les étapes
de préparation des permissions, catalogage et mise en file, leur ordre, les
requêtes SQL, le protocole Liquidsoap et les contrôles de sortie restent en place.

## Tests

Sept assertions complètent le cas 1053 : Latin-1, BMP/japonais, emojis,
combinaisons Unicode, fichiers déjà fonctionnels, documents invalides et chemin
de fin de téléchargement. Les 50 anciennes assertions sont conservées. Aucun
nouveau fichier de fixture ou cas numéroté ; les 1 156 cas restent présents.

Les sondes créent de vrais fichiers JSON en octets UTF-8 et appellent le vrai
lecteur. Les critères vérifient valeurs exactes, absence de warning/log parasite
et conservation des octets du sidecar. Les contrôles nominaux couvrent aussi
les échappements Unicode JSON, les replis d'artiste, les valeurs vides et zéro.
JSON invalide, forme non HASH, UTF-8 invalide et sidecar absent gardent le repli.

Le dernier critère appelle le vrai _finish_download avec un MP3 de fixture,
stdout/stderr de fixture et sidecar Unicode. Seuls _insert_mp3, le client de
sortie Liquidsoap, _say et le log terminal sont substitués : les champs destinés
au catalogue, le chemin mis en file et le message de succès sont observés,
sans base ou sortie IRC réelle. Les fichiers audio/sidecar restent identiques ;
les fichiers temporaires stdout/stderr sont retirés comme avant.

Les nouveaux critères passent 7/7 sur le candidat, 1/7 sur la référence. Les
50 anciennes assertions passent dans les deux arbres, soit 57/57 contre 51/57
avec le cas étendu. Deux mutations des frontières de décodage sont détectées,
avec six nouveaux critères en échec chacune ; les anciennes assertions passent.

Quatre-vingt-un sidecars déjà fonctionnels sont comparés : 72 combinaisons de
priorité artiste, titre, présence d'identifiant et sérialisation ASCII/UTF-8,
puis neuf documents Unicode sérialisés avec des échappements ASCII. Valeurs et
flags UTF-8 retournés sont identiques entre arbres ; aucun warning ou log
observé, et les octets/modes des fichiers sont conservés.

Le groupe radio/Icecast/Liquidsoap/arguments yt-dlp/encodage passe 451/451 sur
26 fichiers ; audit des 37 invariants et intégrité de démarrage passent.
QUALIFICATION.md détaille les suites complètes et l'installation/restauration.

Aucun schéma de base/API, SQL de production, plugin, configuration privée,
VERSION, service, Partyline, runner ou audit n'est modifié. Aucun yt-dlp,
Liquidsoap, Icecast, téléchargement extérieur ou IRC réel n'est utilisé par
ces sondes. Toute la suite reste obligatoire sur le serveur avant commit.
