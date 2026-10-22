# MB911 — Retirer uniquement la commande que le montage possède encore

Date : 22 octobre 2026. Base : `snap_mediabot_v3_teuk_20261022_163536.zip`,
VERSION `3.6dev-20261022_143522`.

## Défaut confirmé

Les descripteurs de commandes v3 gardaient nom, source et éventuellement un
built-in à restaurer. Le nettoyage par nom pouvait retirer une nouvelle entrée
installée entre-temps. Un ancien repli pouvait aussi écraser un remplaçant.
Si l'ancien nom était devenu l'alias d'une autre commande, la restauration du
built-in pouvait lever et interrompre le déchargement. Les rollbacks de montage
partiel et d'échec de ressources partageaient cette lacune.

## Correction

Le montage conserve la référence exacte renvoyée par CommandRegistry. Le helper
commun _unmount_command_registration vérifie l'entrée courante avant retrait ou
restauration. Une autre référence est préservée, y compris si elle porte le même
libellé plugin ou est trouvée via un alias. La référence conservée empêche la
réutilisation de son adresse pendant la comparaison.

Si l'emplacement est vacant, le repli historique peut être restauré comme avant.
Si l'inscription est encore détenue, le retrait nominal reste identique. Les
descripteurs sont vidés après nettoyage. Les anciennes formes sans inscription
conservent leur logique ; aucun changement du registre ou des montages v1/v2.

Le helper sert au rollback local des commandes et au démontage d'une entrée,
donc aussi au rollback d'un échec de ressource après montage des commandes.
Politiques, capacités, invocations et services de données restent inchangés.

## Validation

Le fixture MB908 est étendu sans réécrire ses anciens contrats. Dix critères
complètent le cas 1072. Les vrais RuntimeV3, PluginManager, CommandRegistry,
EventBus, loop IO::Async et Scheduler du fixture sont utilisés. Les remplacements
passent par le vrai registre ; les échecs sont injectés avant un montage de
commande ou une souscription d'événement. Les jobs du témoin sont nettoyés par
les chemins réels. Aucun HTTP, IRC réel, SQL ou base existante n'est sollicité.

Les critères passent 10/10 candidat, 4/10 référence. Les six défauts reproduits
couvrent les remplaçants normal/migré/même libellé, le successeur par alias,
le rollback de commande et le rollback de ressource. Les quatre cas déjà valides
couvrent unload nominal, emplacement vacant et les deux rollbacks sans remplaçant.
Les commandes privées indépendantes sont préservées et l'inscription retirée
est libérée dans le cas nominal. Cinq mutations sont détectées.

Vingt-quatre cycles nominaux comparent les six paquets v3 fournis, avec grants
vides/complets et activation oui/non. Les registres avant/après sont identiques
dans chaque arbre, y compris les références attendues de handlers, aliases et
métadonnées. Les clichés normalisés des deux arbres sont identiques. Scheduler
et EventBus ne gardent aucune tâche ou souscription de ces cycles ; aucun job
de domaine n'est déclenché pendant cette comparaison.

Le groupe plugins/API v3 passe 2 711 assertions sur 133 fichiers. Les 37
invariants et l'intégrité de démarrage passent. Les full suites et la livraison
sont détaillées dans QUALIFICATION.md. Le validateur garde toute la suite
obligatoire sur le serveur, sans exemption.

Six chemins : cinq modifications et une note nouvelle. Aucun nouveau fixture
ou cas numéroté. Aucun schéma de base/API, SQL de production, configuration privée,
VERSION, paquet de plugin, service, Partyline, runner ou audit n'est modifié.
Le paquet ne commit, ne push et ne restart pas automatiquement.
