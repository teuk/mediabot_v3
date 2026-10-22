# MB910 — Activation partielle : tenter stop après un start qui lève

Date : 22 octobre 2026. Base : `snap_mediabot_v3_teuk_20261022_161413.zip`,
VERSION `3.6dev-20261022_141344`.

## Défaut confirmé

PluginManager::enable marquait l'objet démarré après le retour normal de start.
Quand ce hook créait des ressources puis levait, le rollback arrêtait les jobs
du core mais omettait le hook stop. Un countdown et un listener natifs créés par
un témoin restent alors actifs après l'échec, y compris via load_package_v3
avec enable. Une nouvelle tentative peut conserver ces anciennes ressources.

## Correction

Le gestionnaire marque la tentative avant l'appel. Si l'activation échoue,
il essaie stop(context => le même contexte), après l'arrêt des jobs existant.
L'appel reste protégé pour préserver l'erreur initiale si stop lève lui aussi.
L'indicateur n'est pas posé quand aucun hook start n'est appelé.

Les hooks signalent leur échec par exception. Un retour faux seul conserve
son comportement antérieur. Les échecs de démarrage de job après un start réussi
gardent leur rollback et les objets sans start ne gagnent pas d'appel stop lors
de ce rollback. Les règles normales de disable/unload restent identiques.

Le nettoyage est tenté sans garantie : les plugins doivent écrire un stop sûr
après initialisation partielle. Le core ne peut pas annuler arbitrairement les
effets d'un hook dont le nettoyage échoue ou qui ne fournit pas de stop.

## Validation

Neuf critères complètent le cas 1068 dans un Perl frais. Le fixture charge des
témoins temporaires via le vrai RuntimeV3/PluginManager et les vrais registry,
EventBus, Scheduler et loop IO::Async. Les countdowns expirent réellement ; les
listeners sont émis et comptés. Des contrôles privés au fixture injectent les
exceptions, retours et collaborateurs du témoin ; aucune API publique ne change.

Les critères passent 9/9 candidat, 4/9 référence. Les cinq défauts reproduits
couvrent l'échec natif après allocation, une nouvelle tentative, load+enable,
l'exception de nettoyage préservant l'erreur initiale et l'échec avant allocation.
Les quatre critères déjà valides couvrent l'activation normale, le retour faux,
l'échec de job et le rollback sans hook start. Quatre mutations sont détectées.

Le groupe plugins/API v3 passe 2 701 assertions sur 133 fichiers ; les 37
invariants et l'intégrité de démarrage passent. Les full suites locales et les
contrôles du paquet sont détaillés dans QUALIFICATION.md. Le validateur impose
toute la suite sur le serveur, sans exemption.

Six chemins, quatre modifiés et deux nouveaux ; aucun nouveau cas numéroté.
Seul enable change en production. Aucun schéma de base/API, SQL de production,
configuration privée, VERSION, paquet de plugin, service, Partyline, runner ou
audit n'est modifié. Le paquet ne commit, ne push et ne restart pas automatiquement.
