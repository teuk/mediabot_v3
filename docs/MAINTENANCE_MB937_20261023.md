# MB937 — Suppression des citations : résultat SQL confirmé

Base : snap_mediabot_v3_teuk_20261023_222249.zip, VERSION
3.6dev-20261023_201357. Aucun changement de schéma ou de configuration.

## Défauts reproduits

Les chemins historique et v3 annonçaient une suppression après un execute
réussi, même si DBI renvoyait son zéro vrai (0E0). Une citation supprimée entre
la lecture de permission et le DELETE produisait donc une fausse confirmation.
Le chemin historique supprimait par ID seul après une lecture limitée au canal.
Une citation déplacée entre ces opérations pouvait être supprimée ailleurs.
Ce déplacement est une mutation SQL contrôlée dans la reproduction ; aucun
nouveau déplacement de citation n'est ajouté aux commandes.

Une erreur fetch pouvait être assimilée à une absence. Dans le lecteur partagé
v3, cela concernait aussi la recherche de doublon avant ajout. Les exceptions
prepare/execute du chemin historique n'étaient pas contenues avec RaiseError.

## Correction

Les deux suppressions lisent rows avant finish : zéro renvoie l'issue existante
not_found, un compteur inconnu est une erreur, et seul un compteur positif
permet la confirmation. Le chemin historique lie également id_channel depuis
la ligne consultée. La journalisation de réussite reste après cette validation.
Les erreurs de lecture sont vérifiées avant finish et ne deviennent pas une
absence. Les erreurs v3 restent bornées à data service unavailable ; les erreurs
historiques gardent leur notice Database error et sont contenues.

Cette correction ne crée pas de transaction et ne promet pas qu'une erreur
après un DELETE annule une suppression déjà faite. Elle évite d'annoncer une
réussite non confirmée. Les transactions éventuellement ouvertes par un appelant
restent sous sa responsabilité, comme auparavant.

Auteur par id_user, Administrator+, seuil canal configurable et citation anonyme
conservent leur politique. Syntaxe, badges, couleurs, Unicode, message de succès,
façade historique et routage Context restent identiques. Aucun plugin n'est
activé et aucune base du bot n'est contactée par la qualification.

## Vérification

Le cas 561 remplace une table de vérité recopiée et des regex de source par sept
groupes dans un interpréteur enfant : vrais modules, DBI et SQLite. Les requêtes
de production s'exécutent sans traduction SQL. Les courses sont injectées juste
avant le vrai DELETE ; un trigger SQLite produit aussi un vrai zéro sans effacer
la ligne. Le même zéro est également présenté sous sa forme vraie Perl 0E0,
sans simuler la persistance, afin d'exiger une comparaison numérique positive.
Les fautes DBI sont exercées avec RaiseError à 0 et à 1.

Les groupes couvrent succès/Unicode/canal/façades, permissions et seuils, courses
et zéro réel, changement de canal, erreurs SQL, compteurs inconnus/absence, et
recherche de doublon v3 défaillante. Ils comparent sorties et état persistant.
Le mock du cas 1101 expose désormais err et rows, les méthodes DBI utilisées.
Le catalogue reste à 1 158 fichiers de cas ; sept assertions sont retirées.

Le paquet inclut une qualification avec les résultats complets, les mutations,
les limites de l'environnement local et les contrôles d'installation/restauration.
Sur le serveur, apply_test.sh exige syntaxe, groupe ciblé, suite entière sans
filtre, audit sécurité et intégrité de démarrage. Tout échec restaure les seuls
fichiers de la tentative ; aucune exception n'est ajoutée au validateur.
