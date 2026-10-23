# MB918 — Objets de canal et reconnexion SQL

Date : 23 octobre 2026. Base exacte :
`snap_mediabot_v3_teuk_20261023_092059.zip`.

## Défaut reproduit

Le keepalive existant resynchronise l'alias dbh du bot quand Mediabot::DB renvoie
un nouveau handle. Les objets Channel déjà conservés dans le cache gardent
cependant leur ancien dbh. Les trois points de construction ne passent pas le
propriétaire de connexion, et le constructeur ne le stocke pas. Même la branche
ensure_connected prévue dans _execute_update reste donc sans effet pour eux.

Avec de vrais handles DBI/SQLite locaux, la référence conserve une connexion
explicitement fermée après la reconnexion du propriétaire. Les sept setters
échouent, get_user_level renvoie zéro, get_user_info ses valeurs de repli et les
opérations d'identité/création échouent, malgré un nouveau handle fonctionnel.
La reproduction ne contacte aucun serveur SQL ou IRC réel.

## Correction et partage

Channel conserve un propriétaire db optionnel. Le helper privé _current_dbh
utilise son ensure_connected existant, actualise le dbh du canal et retourne ce
handle. Si le propriétaire ne retrouve aucune connexion, le canal vide son alias
au lieu de conserver un handle connu périmé. Sans propriétaire compatible,
le chemin historique fondé sur dbh seul est conservé.

Le helper est commun aux updates, get_user_level, get_user_info, exists_in_db et
create_in_db. Les trois points de création réels transmettent db :

- Mediabot::populateChannels ;
- ChannelCommands::get_channel_by_name ;
- ChannelCommands::addChannel_ctx.

Les requêtes et leurs paramètres, validations, retours des setters et conventions
de nombre de lignes restent identiques. Les getters purement en mémoire restent
purement en mémoire. Les erreurs de reconnexion rendent les replis conservateurs
existants ; les métadonnées en mémoire ne sont pas annoncées comme modifiées par
un setter en échec. Le diagnostic de reconnexion appartient toujours à Mediabot::DB.

Les opérations SQL d'un canal avec propriétaire ajoutent son contrôle existant
de connexion. Aucun nouveau keepalive, timer, timeout, retry de requête ou algorithme
de reconnexion n'est ajouté. Le DB wrapper et le keepalive du bot sont inchangés.
Le correctif n'étend pas la reprise à tous les autres détenteurs de handles du bot.

## Vérifications

Neuf critères complètent le cas 65 ; ses 36 anciennes assertions restent intactes.
Un sous-processus charge les vrais propriétaires et utilise un fichier SQLite
privé, des handles DBI réels, les vraies requêtes et les trois fabriques d'objets.
Le vrai ensure_connected est conservé ; seul _connect est remplacé par la
réouverture du fichier local. Les sorties, liaisons IRC et autorisations du Context
de fixture sont contrôlées. Aucune base existante ou configuration privée n'est lue.

Les critères couvrent les sept setters après reconnexion par chaque fabrique,
les trois lectures vérifiées sur des objets frais indépendants, l'insertion et
son identifiant, la reconnexion déclenchée par le canal, le propriétaire indisponible
et le contrat dbh seul. Ils passent 9/9 candidat, 2/9 référence ; sept critères
reproduisent le défaut. Les anciens critères passent dans les deux arbres, soit 45/45
contre 38/45 avec le cas étendu.

Une comparaison séparée de 81 vecteurs natifs vérifie les trois fabriques,
valeurs normales/vides/zéro, lectures, création, validations refusées et échecs
SQL par trigger. Retours, champs de cache, traces SQL et binds, données disque et
logs sont identiques. Trois scénarios supplémentaires rétablissent le propriétaire
après une indisponibilité : le handle a été vidé, puis les updates et droits
fonctionnent de nouveau. Neuf mutations indépendantes sont détectées, sans
faire échouer les 36 anciens critères.

Le groupe ciblé passe 284 assertions sur 12 fichiers. Les quatre syntaxes,
l'audit des 37 invariants et l'intégrité de démarrage passent. QUALIFICATION.md
consigne les suites complètes, leurs limites et le rehearsal de restauration.
Toute la suite reste obligatoire sur le serveur.

Six chemins : cinq modifiés et cette note nouvelle ; aucun nouveau fichier de
fixture, module ou cas numéroté. Les 1 156 cas restent. Aucun schéma de base,
migration, SQL de production, configuration privée, VERSION, service, plugin,
Partyline, radio, runner ou audit n'est modifié. Aucun commit, push ou restart
automatique.
