# MB935 — Ajout de timers sans état partiel

Base : `snap_mediabot_v3_teuk_20261023_202832.zip`, VERSION
`3.6dev-20261023_182815`. Aucun changement du schéma de base de données.

## Défauts reproduits

La revue générale a parcouru notamment User, Auth, DynamicTemplate, Convert,
NetworkStats, RandomQuote, Scheduler, ReplyQueue, EventBus et DBCommands. Les
corrections retenues concernent `addtimer`, dont l'entrée SQL était conservée
avant la construction, l'attachement et le démarrage du timer natif. Un échec
laissait une ligne susceptible d'être activée au prochain reconnect, malgré
l'échec de la commande. Un attachement ou démarrage partiel pouvait aussi
laisser un notifier non publié dans hTimers. Les exceptions remontaient au
dispatcher au lieu de produire un résultat local propre.

La commande pouvait aussi annoncer un succès à l'intérieur d'une transaction
appartenant à son appelant : le timer devenait actif même si cette transaction
était ensuite annulée. Une erreur de fetch pendant la recherche de doublon
pouvait être prise pour une absence et laisser l'ajout continuer.

## Correction

Après les validations existantes et la recherche de doublon, la commande ouvre
sa propre transaction, insère la ligne, construit puis attache/démarre le timer.
Le callback reste inactif pendant cette préparation. Le commit est contrôlé ;
l'entrée hTimers et l'activation du callback ne sont publiées qu'après succès.
Les transactions déjà ouvertes sont refusées sans lire ou modifier leurs données,
sans commit et sans rollback de leur travail.

Un échec SQL ou natif révoque d'abord le callback, termine le statement, tente
indépendamment stop et remove puis annule uniquement sa propre transaction.
Les erreurs de rollback sont journalisées. Aucun succès ni événement d'audit
d'ajout n'est annoncé sur ces chemins. Une nouvelle tentative peut alors créer
le même nom après rétablissement du composant en panne.

Le callback utilise des références faibles et vérifie l'identité de son timer
dans hTimers. Le conserver après un retrait ou un remplacement ne permet plus
d'envoyer des commandes ni de retenir le bot ou le timer indéfiniment.

La syntaxe, les noms, les intervalles 5..86400 secondes, les verbes autorisés,
le contrôle Owner, le format de confirmation, le texte Unicode et le helper
IRC qui refuse CR/LF/NUL restent conservés. Le chemin remtimer est inchangé.
Les timers DB existants continuent à fonctionner pendant un ajout raté.

## Validation

Le cas `68_timer_add_remove_db_safety.t` remplace ses treize vérifications de
structure par huit groupes de scénarios natifs et un contrôle du processus
enfant. Le cas mb369 reconnaît le récepteur résolu depuis la référence faible.
Le catalogue reste à 1 158 cas, avec quatre assertions de moins.

La fixture utilise de vraies bases DBI/SQLite privées, des timers Periodic et
une boucle IO::Async. Seul le premier délai des timers du probe est ramené à
zéro ; l'intervalle récurrent de production reste inchangé. Les fautes sont
injectées avant et après les effets réels d'add/start et après ceux de stop/remove.
Une contrainte différée provoque un véritable échec SQL au commit. Une seconde
connexion contrôle la visibilité du nouveau timer. Le SQL n'est pas traduit.

Les scénarios couvrent succès via module/façade, Unicode, livraison native,
construction/add/start, erreurs prepare/execute/fetch/begin/insert/commit avec
RaiseError 0 et 1, transaction appelante, récupération, callbacks précoces et
tardifs, libération des références, permissions, doublons, garde IRC et retrait
avec ligne SQL présente ou déjà absente. Ils ne constituent pas une intégration
MariaDB réelle et ne contactent aucune base ou connexion IRC du bot.

La qualification jointe au paquet fournit les suites entières référence/candidat,
les mutations et les limites locales. Le validator livré conserve obligatoirement
la suite complète sans filtre, l'audit sécurité et l'intégrité de démarrage.
L'installateur conserve sauvegardes, préconditions par empreinte, modes, absences
et rollback. Aucun redémarrage, commit ou push n'est automatique.
