# MB908 — API v3 : rattacher callbacks et sorties à leur instance

Date : 22 octobre 2026. Base : `snap_mediabot_v3_teuk_20261022_151703.zip`,
VERSION `3.6dev-20261022_131646`.

## Défauts confirmés

Les gardes v3 utilisaient is_enabled(nom). Une ancienne invocation de commande
ou de job retrouvait donc ses sorties après unload/reload et enable du même nom,
y compris si le successeur n'avait plus irc.reply. Un handler, listener ou callback
retenu pouvait encore invoquer l'ancien objet. Le Scheduler et l'EventBus ont leurs
propres barrières, mais les closures du gestionnaire n'avaient pas cette identité.

Dans un job diffusé vers plusieurs politiques de salon, un premier handler
pouvait désactiver/décharger son plugin. La boucle continuait vers les autres
salons à partir de son ancienne liste.

## Changement

PluginManager factorise un garde privé _v3_entry_is_current : l'entrée courante
doit être la référence exacte capturée au montage. Ce garde complète les contrôles
existants dans les commandes et leurs sorties reply/notice, les deux frontières
d'événement, les jobs et leurs sorties channel_message. La boucle des salons
revérifie aussi identité et activation avant chaque handler.

Une closure de commande périmée devient silencieuse avant de considérer son
ancien repli. L'instance actuelle garde ses replis observe/off/disabled, sa
quarantaine et ses politiques. La désactivation/réactivation sans unload garde
ses sémantiques existantes ; aucune nouvelle génération n'est ajoutée.

Un handler déjà exécuté n'est pas interrompu. Le garde ne transforme pas les
plugins Perl de confiance en sandbox. Les façades HTTP/données et leur autorité,
les contrats de manifeste/API, le scheduler et l'EventBus ne sont pas réécrits.

## Validation

Quatorze critères complètent le cas existant 1072. Le fixture charge un paquet
témoin temporaire avec les vrais gestionnaire, registry, EventBus, IO::Async et
Scheduler. Le scénario nominal laisse réellement expirer un timer natif et
drainer les événements différés. Les autres invoquent volontairement des closures
retenues ou réentrent dans disable/unload depuis un handler. Les sorties sont
capturées : aucun réseau IRC/HTTP ou base existante n'est sollicité.

Les critères passent 14/14 candidat, 3/14 référence. Les trois déjà valides couvrent
le chemin natif, politique/quarantaine et replis courants. Les onze autres
reproduisent les défauts d'identité et de fan-out. Dix-huit vecteurs nominaux
off/observe/on, un à trois salons, avec/sans disable/enable donnent des sorties,
retours, compteurs et portées d'invocation identiques. Six mutations sont détectées.

Le groupe plugins/API v3 passe 2 679/2 679 assertions sur 133 fichiers ; les
37 invariants et l'intégrité de démarrage passent. Les full suites locales
rencontrent MB786 dans les deux arbres et MB647 seulement dans la référence.
Voir QUALIFICATION.md pour les comptes, la sonde Doctor et les limites. La suite
locale n'est pas déclarée entièrement verte ; le validateur impose tous les
contrôles sur le serveur, sans exclusion.

Six chemins, quatre modifications et deux créations. Quatorze assertions en
plus, aucun nouveau cas numéroté. Aucun schéma de base, SQL de production, paquet
de plugin, configuration privée, VERSION, service, code Partyline, runner ou
outil d'audit n'est modifié. Le paquet est réversible et ne commit/restart pas.
