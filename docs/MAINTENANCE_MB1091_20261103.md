# MB1091 — Horloges cohérentes pour les durées Hailo

## Source et périmètre

Snapshot snap_mediabot_v3_teuk_20261103_211226.zip, MB1090 présent,
VERSION 3.8dev-20261103_201215. Sept chemins : Policy, ReplyQueue,
PostEditRuntime, deux cas existants1023/1025, changelog et cette note.
Aucun schéma, donnée, configuration, dépendance ou VERSION modifié.
README racine, DDG, Wikipédia, radio, YouTube et commit.sh privé conservés.

## Défauts et correction

Les durées Hailo reposaient encore sur time() : un ajustement de l'heure civile
pouvait prolonger un cooldown ou faire expirer une réponse trop tôt. Les
horloges par défaut utilisent désormais CLOCK_MONOTONIC de Time::HiRes,
comme les autres mécanismes de délais du projet. Cela ne change aucun
horaire calendaire, fuseau ni format d'horodatage persistant.

Le runtime et la file pouvaient en outre employer des origines différentes.
Il suffisait de fournir clock au runtime sans fournir de file, ou de fournir
une file à horloge injectée sans répéter clock au runtime. À la prise en charge,
le runtime remplaçait son queued_at par celui de la file puis calculait l'âge
avec sa propre horloge. Une réponse vieille pouvait rester admissible parce
que la différence était négative, ou une réponse fraîche expirer aussitôt.

Une file implicite reçoit maintenant l'horloge explicite du runtime. Sans
horloge explicite, le runtime suit la méthode publique now() de la file
native. Les adaptateurs externes sans now() restent acceptés et utilisent
l'horloge monotone du runtime par défaut.

L'âge total d'un job reste attaché à sa soumission dans le runtime : le
queued_at d'une file externe ne le remplace plus. La file conserve son
propre contrôle du temps passé en attente. La durée totale inclut toujours
attente, fournisseur et délai de frappe. Les contextes suivent la même
horloge que le runtime. La politique conserve ses seuils/configurations,
son tirage aléatoire et ses compteurs.

Les timestamps concernés sont uniquement en mémoire. Aucun cerveau Hailo,
fichier de données ou historique n'est migré. Les horloges injectées existantes
restent supportées. Un callback d'horloge invalide conserve le repli, désormais
monotone ; il n'est pas interprété comme une horloge civile de substitution.

## Tests et livraison

Quatre assertions groupées ajoutées aux deux cas existants. Aucune attente,
requête réseau ou nouveau processus de test. Horloge monotone simulée distincte
de l'heure civile, frontières exactes/fractionnaires de TTL et cooldown,
anti-flood, file implicite, horloges externes différentes et suivi du contexte
sont exercés. Les251 contrôles ciblés de neuf fichiers passent en une seconde.
Les résultats détaillés de full et du paquet sont dans QUALIFICATION.md.

Application idempotente et staging limité aux contenus cumulés qualifiés,
suppressions précédentes conservées. Full suite visible --progress/ETA,
audits sécurité/startup, inventaire/whitespace avant staging/restart/commit.
Dev seul avec PID différent puis stable dix secondes. commit.sh natif
--skip-preflight reste interactif et gère automatiquement VERSION3.8dev.
Aucun contrôle WorkingDirectory. Aucun service réel, SSH ou commit/push
exécuté pendant la préparation ; le PID ne prouve pas la reconnexion IRC.
