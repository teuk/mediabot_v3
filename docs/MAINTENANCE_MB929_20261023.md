# MB929 — Liens de morceau Apple Music vers Spotify et YouTube

Base : `snap_mediabot_v3_teuk_20261023_150252.zip`, VERSION
`3.6dev-20261023_130244`. Cette livraison ajoute une fonctionnalité explicitement
optionnelle, au lieu de modifier les règles des autres chansets.

Le nouveau module `Mediabot::External::AppleMusicFallback` possède le rapprochement,
la politique fermée par défaut, les quotas, le cache et le cycle de vie des
recherches. `AppleMusic.pm` lui transmet uniquement les métadonnées de lookup
exactes, en conservant l'annonce et les alias historiques. Le badge Spotify est
extrait dans un seul helper utilisé par les deux chemins ; le badge YouTube
existant est réutilisé directement. Deux anciens tests de localisation du dessin
du badge sont adaptés en vérifications de ses octets exacts.

`ChannelCommands.pm` conserve son authentification et ses permissions existantes.
Une commande explicite autorisée inscrit au besoin une entrée de catalogue,
sans DDL, puis active seulement le salon demandé. La désactivation révoque les
réponses déjà en attente, même après réactivation. Aucun appel HTTP, changement
de schéma ou adoption implicite n'est ajouté à la commande.

Une fixture isolée avec DBI/SQLite exerce les vrais handlers de chanset, Context,
Channel, parseurs, caches et contexte de livraison. 27 scénarios regroupés
couvrent les chemins nominaux, refus et pannes, l'identité Unicode et la durée,
les URLs hostiles, les limites de ressources, les doublons et l'annulation.
Le test natif utilise de vrais processus IO::Async et les collecteurs HTTP réels
avec un transport HTTP simulé : l'annonce AppleMusic et les deux liens sont
produits sans HTTP dans le parent. Un seul fichier de cas est ajouté ; les
1 156 anciens restent présents. Le catalogue passe donc à 1 157 fichiers.

Le contrôle `tools/applemusic_fallback_check.pl` ne contacte aucun service sans
`--live`. Il n'écrit ni en base ni dans la configuration et n'envoie rien sur IRC.
Les limites d'acceptation et commandes sont détaillées dans
[APPLE_MUSIC_FALLBACK.md](APPLE_MUSIC_FALLBACK.md).

Les tests HTTP sont déterministes et hors réseau. Aucune acceptation réelle des
clés/services du dev n'est affirmée dans cette qualification locale. Le paquet
conserve la vérification de l'intégrité, les neuf tests de son installateur,
l'application gardée par empreintes, la sauvegarde et le retour arrière.
L'application sur le dev exige toujours syntaxe, cible, suite complète non
filtrée, 37 invariants de sécurité et contrôle d'intégrité au démarrage.

Ni VERSION, configuration privée, fichiers de schéma/migration, script de commit
ou services en fonctionnement ne sont modifiés par cette livraison.
