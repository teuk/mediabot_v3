# MB1072 — Mesurer les tâches avec une horloge monotone

## Défaut et correction

Les durées du scheduler utilisaient gettimeofday/tv_interval et celles des
workers soustrayaient deux timestamps civils. Une correction NTP ou une mise
à l'heure manuelle produisait des durées négatives ou une tâche artificiellement
longue. Cela affectait les profils du shell, le tri des workers, leurs résultats
et l'histogramme des callbacks ; une avance pouvait aussi déclencher un faux
SLOW SCHEDULER.

Scheduler mesure maintenant le coût de chaque callback avec CLOCK_MONOTONIC.
AsyncWorker garde son timestamp started_at et ajoute un marqueur monotone au
lancement. Un unique helper privé alimente ps et le résultat final, avec un
plancher à zéro. Aucun nouveau champ n'est ajouté au contrat public du résultat.

L'horloge civile reste utilisée pour start_time, last_tick, next_run et les dates
d'exception du scheduler. La résolution des tâches calendaires, les timers,
les délais d'expiration, la terminaison TERM/KILL, le protocole pipe/JSON, les
identités et la propriété des workers ne sont pas modifiés. Ce correctif porte
sur la mesure du coût, sans prétendre changer les horloges de l'event loop.

Le registre ACTIVE survit volontairement au reload du module : un worker déjà
lancé par l'ancien code n'a pas de marqueur monotone. Il conserve l'ancienne
estimation civile, bornée à zéro, jusqu'à sa fin. Les nouveaux workers utilisent
le marqueur ; le restart dev du modop enlève naturellement ce cas transitoire.

## Vérification et taille de suite

749 : dix assertions natives remplacent dix-sept contrôles, dont des pins de
code/câblage. Sur le vrai scheduler : retours/avances de l'horloge civile avec
coûts monotones déterministes, vraie tâche lente, exception, stats cumulées et
maximales, vrai rendu d'histogramme Prometheus, projection absente ou défaillante,
callbacks de timers periodic/calendar et conservation des dates epoch.
Les timers sont natifs et leurs événements invoqués sans attente artificielle ;
les autres cas de lifecycle continuent à couvrir la vraie boucle événementielle.

1404 conserve trente assertions : ses tests de snapshots et de résultat final
vérifient aussi les sauts d'horloge dans les deux sens et la forme d'un worker
pré-reload. Le vrai child résistant reste annulé, escaladé et récolté par la vraie
boucle, une seule fois. L'injection d'horloge est limitée à l'observation et à la
construction du résultat ; elle ne fausse pas les timers d'IO::Async.

Pas de nouveau fichier de test, sept assertions en moins. Aucun sleep long
ajouté. Les contrôles de warnings, d'isolation entre boucles, d'ID périmés et
d'annulation restent actifs. Les résultats locaux et leurs limites figurent
également dans QUALIFICATION.md du paquet.

## Déploiement

Le paquet vérifie ses empreintes et les états exacts avant/après, accepte sa
réapplication, puis exige la full visible --progress/ETA, les audits sécurité et
startup, l'inventaire et diff --check. Il conserve les changements précédemment
qualifiés encore en attente et leurs suppressions, sans embarquer les fichiers
privés ni de changement versionné étranger.

Après réussite seulement : staging qualifié, restart mediabot@dev.service seul,
nouveau PID stable dix secondes puis commit.sh installé et interactif. VERSION
reste automatique en 3.8dev ; aucun edit manuel ni remplacement du helper privé.
Le contrôle de processus ne prouve pas la reconnexion IRC. Aucun schéma SQL,
fichier de configuration, dépendance, radio/YouTube, README racine ou service
de production n'est modifié.
