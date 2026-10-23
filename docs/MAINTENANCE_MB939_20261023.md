# MB939 — Observer les cadences et tâches sans modifier leur état

Base : snapshot `snap_mediabot_v3_teuk_20261023_231334(1).zip`, complété par le
payload MB938 vérifié et la VERSION `3.6dev-20261023_214729` confirmée dans le
compte rendu du commit serveur `05d171b`. Aucun nouveau snapshot ou accès
au serveur n'est prétendu. Les préconditions SHA-256 portent sur chaque chemin.

## Résultat de roadmap

MB938 est installé, validé et poussé. MB939 commence l'étape 2 : le même
diagnostic privé `.diagnose #salon` décrit les cadences RSS, les tentatives
RandomQuote et les deux tâches attendues du scheduler d'instance. Il ajoute
quatre lignes au maximum, pour un rapport plafonné à dix-sept lignes.
Le format structuré devient version 2, en conservant les observations MB938.

Les runtimes proposent une méthode explicite `diagnostic_status`. Le collecteur
n'instancie pas de runtime de remplacement : un composant absent reste inconnu.
Les classes d'état réutilisent leurs propres validateurs et calculs de statut.
Une nouvelle lecture JSON commune ouvre uniquement les fichiers existants en
lecture, prend brièvement le verrou partagé non bloquant et borne la lecture
à 262 144 octets. Elle refuse symlinks, fichiers spéciaux et paires état/verrou
incomplètes. Elle ne crée aucun répertoire, fichier ou verrou et ne change pas
les permissions. Elle ne remplace pas les lecteurs décisionnels `status`.

Les lecteurs historiques peuvent créer ou protéger un verrou ; le diagnostic
n'utilise donc pas ces chemins. Les écritures et décisions des composants
conservent leur protocole actuel. Une collision avec un verrou exclusif est
signalée immédiatement, sans attente ni réparation.

## Lire les observations

- RSS : gap en minutes, quota glissant sur 24 h, réservations récentes et délai
  imposé par la politique. Une réservation peut précéder un envoi IRC refusé.
- RandomQuote : intervalle effectif du runtime, source par défaut ou spécifique,
  prochaine tentative enregistrée, délai et ticket pending. Un fichier ou une
  ligne absente ne possède pas d'échéance ; le diagnostic n'en invente aucune.
  Un ticket n'est pas la preuve d'un worker actif ou d'une citation envoyée.
- Scheduler : deux noms fixes, tâches présentes/absentes ou inconnues faute de
  scheduler, état démarré/arrêté, ticks, dernier tick, prochain réveil et retard
  observé. Les tâches sont globales à l'instance. Les ticks comptent des entrées
  de callback, pas des succès. Aucun callback n'est invoqué par le diagnostic.
- Date du fichier : mtime du document entier, pas dernier envoi du salon ni
  date de succès. Une lecture fraîche ne garantit pas une donnée métier récente.

Les flags persistés, le JOIN et les cadences restent des observations distinctes.
Le rapport ne déduit pas une activation de la présence d'un fichier, et ne
prétend pas constituer un snapshot atomique entre SQL, fichiers et scheduler.

## Validation et limites

Le cas 07 garde les sept groupes MB938 et ajoute six groupes natifs : fichiers
absents et défauts, politiques et tickets réels, fichiers occupés/invalides/
incomplets/symlinks/FIFO, cycle du scheduler réel, sorties Telnet/DCC Unicode et
droits avant accès aux composants. Les dates, octets, modes et inodes des
fichiers sont comparés ; un ticket reste consommable après observation.
Le protocole de verrouillage est exercé avec de vrais descripteurs et flock.
Les callbacks de timer sont déclenchés explicitement par la fixture pour
vérifier les compteurs, jamais par le collecteur. Aucun réseau distant n'est utilisé.

Le catalogue reste à 1 158 cas : six assertions supplémentaires dans le cas 07,
plus six contrôles de structure existants pour les deux nouveaux modules.
La qualification du ZIP détaille les résultats effectifs, mutations et limites
de l'environnement local. Le serveur doit toujours passer les compilations,
le groupe ciblé, la suite complète sans filtre, sécurité et intégrité de démarrage.

Pas de modification du schéma, de VERSION, des réglages privés ou des chansets.
Pas de sondage fournisseur, de réparation d'état, de lecture du texte des
citations ou des erreurs brutes, de route web, de redémarrage ou de déploiement.
Les prochaines étapes restent les observations manquantes puis leur présentation
autorisée dans mbweb. Voir `docs/CHANNEL_DIAGNOSTICS.md` pour le contrat complet.
