# MB900 — Séparer EOF et collecte des processus

## Bug reproduit

Six flux IO::Async lisent des handles ouverts par Perl avec `open '-|'`.
La fermeture d'un tel handle attend et collecte le processus associé. Or
IO::Async::Stream ferme normalement son handle automatiquement lorsqu'il lit EOF,
après le callback de lecture. Les routines applicatives possèdent déjà leur
propre collecte asynchrone, par polling WNOHANG ou watch_process.

Deux mécanismes pouvaient donc collecter le même enfant. Quand le flux fermait
le pipe en premier, le collecteur ne retrouvait plus son statut. Quand l'enfant
fermait stdout puis continuait à tourner, cette fermeture automatique pouvait
attendre sa fin dans la boucle IRC et retarder les timers.

La référence reproduit les conséquences suivantes avec des producteurs locaux :

- `whereis_async` et `_define_lookup_async` remplacent un résultat valide par
  leur repli d'échec lorsque leur wait ne retrouve plus l'enfant.
- `resolve_ctx` et le reverse DNS Partyline peuvent accepter une sortie dont
  le producteur termine avec un statut d'échec ; le statut perdu devient zéro.
- Le worker YouTube peut perdre son callback de fin après une fermeture de
  sortie anticipée, en plus du blocage de la boucle.
- Un `.eval` Owner fermant ses sorties puis continuant à tourner bloque la
  boucle malgré le watchdog prévu pour le terminer.

Ces défauts sont présents dans le snapshot fourni. Ils ne sont pas introduits
par le nouveau fixture. Aucun service externe, base ou bot réel n'est sollicité.

## Correction ciblée

Chaque flux concerné reçoit `close_on_read_eof => 0`. L'EOF reste consommé une
seule fois et retire le lecteur de la boucle ; le collecteur existant reste
responsable du statut. Les finalizers ferment ensuite les pipes après collecte.
Le finalizer `.eval`, qui dépendait de la fermeture implicite, reçoit sa propre
fermeture explicite à cet endroit.

| Fonction | Propriétaire |
| --- | --- |
| `whereis_async` | `Mediabot::External::Country` |
| `_define_lookup_async` | `Mediabot::UserCommands` |
| `_youtube_search_fetch_async` | `Mediabot::External::YouTube` |
| `resolve_ctx` | `Mediabot::Helpers` |
| `_schedule_reverse_dns_lookup` | `Mediabot::Partyline::SessionAuth` |
| `_cmd_eval` | `Mediabot::Partyline::Privileged` |

Les autres workers qui utilisent `pipe`/`fork` avec des handles ordinaires ne
subissent pas cette sémantique spéciale de fermeture Perl et restent inchangés.
Les commandes synchrones utilisant intentionnellement un pipe processus ne sont
pas transformées. Aucun worker n'est migré ou remplacé pendant ce correctif.

Délais, limites de sortie, encodage, TERM/KILL, signatures, hooks, routage et
contrôles Owner/configuration/confirmation de `.eval` restent en place. Les
chemins sans boucle ne changent pas. Le schéma, SQL, les configurations privées,
VERSION, les services, le runner et les outils d'audit ne sont pas modifiés.

## Tests de régression

Quatorze assertions complètent six cas existants : 531, 533, 535, 538, 540 et
543. Aucun fichier de cas numéroté n'est créé ou supprimé. Un fixture partagé
charge les vrais propriétaires dans des interpréteurs Perl frais ; il ne copie
aucun de leurs algorithmes de lecture, collecte, timer ou interprétation.

Les producteurs HTTP sont interceptés ; pour DNS, seul le programme exécuté par
le pipe est remplacé, avec un contrôle du nombre de lancements. Les pipes natifs,
IO::Async, forks, timers, statuts et signaux restent réels. `.eval` exerce ses
véritables gardes et ses deux appels de confirmation, avec une session locale
de fixture et aucun envoi réseau.

Chaque surface vérifie un résultat nominal et un enfant fermant sa sortie puis
ignorant TERM. DNS et reverse DNS ajoutent chacun une sortie plausible suivie
d'un exit 2. Les assertions contrôlent le résultat, le statut observé, la présence
du callback ou de la réponse, les avertissements, un heartbeat et la collecte
finale des enfants. Les délais nominaux sont plus larges que les timeouts de
régression afin de ne pas imposer un démarrage en 0,1 seconde.

Sur la première reproduction Country, la référence rend `N/A` au lieu de `FR`.
Avec une fermeture anticipée suivie de quatre secondes d'activité, le heartbeat
est retardé d'environ quatre secondes. Le candidat rend `FR` ; le heartbeat
arrive vers 0,05 seconde et le timeout TERM/KILL finit vers 0,34 seconde.

La matrice commune emploie des producteurs de cinq secondes. Elle distingue
les corrections attendues des contrôles nominaux déjà réussis. Voir
QUALIFICATION.md pour les mesures, les comptes complets avant/après et les
limites de l'environnement local. Les tests restent des scénarios contrôlés,
pas une validation de tous les ordonnanceurs ou services publics.

Le paquet exige la suite complète non filtrée sur le serveur, l'audit des
37 invariants et l'intégrité de démarrage avant le commit. Son installateur
conserve la sauvegarde, le contrôle préalable global et la restauration gardée.
