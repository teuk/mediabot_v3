# MB1079 — Borner le suivi des pannes HTTP des plugins

Base : snap_mediabot_v3_teuk_20261103_090927.zip.
VERSION : 3.8dev-20261102_182251. Les 399 chemins précédemment qualifiés
correspondent exactement à MB1078 final ; les correctifs antérieurs sont conservés.

## Défaut

Le service HTTP partagé API v3 borne son cache de réponses, mais pas son
dictionnaire de pannes par origine. Une seule réponse en erreur suffit à
conserver une entrée jusqu'à une réponse réussie ou une erreur non réessayable
de cette même origine. Une série de destinations différentes en panne laisse
donc grossir ce suivi sans limite, même avec cache désactivé et aucun worker
encore actif. Le seuil de trois échecs n'empêche pas cette accumulation.

## Correction et limite

Le suivi conserve au maximum 128 origines par instance de service, partagées
entre plugins. Avant une nouvelle admission, il évince une entrée fermée ou
expirée en priorité ; dans chaque groupe, l'échec le moins récent est évincé.
Un numéro d'ordre par entrée assure cette récence même si l'horloge civile
recule. Aucune seconde liste d'origines ne conserve des clés retirées.

Si les 128 entrées sont ouvertes, la moins récemment défaillante est évincée
pour admettre la nouvelle origine. La borne ne bloque donc pas définitivement
les nouvelles destinations. Une origine évincée repart de zéro lors de son
prochain échec ; son ancien délai de circuit n'est plus retenu. C'est le
compromis explicite de cette borne de mémoire, pas un blocage réseau global.
Une entrée existante conserve sa série lors d'un nouvel échec et renouvelle
sa récence. Un ancien suivi surdimensionné est réduit au prochain échec traité ;
un redémarrage ordinaire crée directement un service vide et borné.

Le seuil reste trois erreurs transport/429/5xx pour 60 secondes. Réponse
réussie ou erreur client non réessayable : l'entrée est retirée comme avant.
Une réponse en cache disponible reste prioritaire sur un circuit ouvert.
La définition d'origine, la validation URL/DNS/adresses privées, TLS,
redirections, tailles, budgets worker, annulation et générations sont inchangés.
La même garde terminale rejette les callbacks dupliqués ou révoqués avant
qu'ils puissent modifier le suivi. Le contrat JSON et la documentation API
décrivent la nouvelle borne ; aucune commande ou option de configuration.

## Tests natifs

Le cas 1268 existant exécute les vraies méthodes fetch/_perform_request et
HTTPResponseV3 avec transport/résolution locaux injectés. L'horloge et le
lancement sont contrôlés pour les scénarios de panne, sans réseau externe.
Le test fork/pipe AsyncWorker déjà présent reste intact. Cinq groupes couvrent :

- 137 origines réellement distinctes, borne par défaut 128, survivants exacts,
  contrat JSON, un callback par requête et aucun cache/slot résiduel ;
- éviction des entrées fermées avant un circuit ouvert partagé entre plugins,
  récence par échec et recul de l'horloge ;
- suivi entièrement ouvert, admission d'une nouvelle origine, métriques et
  nouvelle série pour une origine évincée ;
- réponses terminées dans le désordre, callbacks dupliqués ou révoqués après
  annulation, un seul callback accepté et libération de tous les slots ;
- expiration à la frontière exacte, reset par succès puis erreur 404.

L'assertion de cardinalité répétée à chaque appel du helper de succès est
retirée : 26 assertions redondantes en moins, cinq groupes ajoutés, soit 58
au lieu de 79. Les vérifications explicites de cache, TTL, Accept, tailles,
isolation plugin, concurrence, générations et fork sont conservées. Les cas
dédiés de lancement et de callbacks, ainsi que les nouveaux groupes, gardent
la couverture de cardinalité. Aucun nouveau cas, processus ou délai d'attente.
Les cinq nouveaux groupes échouent sur le module intact puis réussissent
avec le correctif. QUALIFICATION.md donne les résultats et limites locaux.

## Exploitation

Six chemins changent : module HTTP, cas 1268, contrat JSON, documentation API,
changelog et cette note. Aucun schéma, donnée persistante, dépendance ou
configuration à modifier. VERSION, README racine, commit.sh privé, runner/ETA,
radio, YouTube et les correctifs précédents sont conservés.

Le paquet contrôle les contenus exacts avant/après et les changements
qualifiés encore en attente. Full visible --progress/ETA sans redirection,
audits sécurité/startup, inventaire et whitespace avant staging/restart.
Après réussite complète : dev seul, nouveau PID stable dix secondes,
commit.sh natif --skip-preflight et VERSION 3.8dev automatique. Un PID stable
ne prouve pas la reconnexion IRC. Aucune intervention en production.
