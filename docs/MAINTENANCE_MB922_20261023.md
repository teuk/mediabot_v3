# MB922 — Bans persistants : retrouver le handle SQL après reconnexion

Date : 2026-10-23. Base : snap_mediabot_v3_teuk_20261023_113905.zip.

## Défaut reproduit

Le démarrage construit un unique Mediabot::ChannelBan avec bot et dbh. Le
keepalive et Mediabot::DB peuvent ensuite remplacer le handle du bot, mais
ChannelBan conservait celui du démarrage. Ses cinq points d'entrée SQL
continuaient donc à préparer leurs requêtes sur ce handle périmé.

Une sonde native déconnecte réellement un handle DBI/SQLite, puis appelle le
vrai Mediabot::DB::ensure_connected pour en ouvrir un nouveau sur le même
fichier privé. Avant correction, le helper ne retrouve plus le ban correspondant,
les listes deviennent vides, ajout/suppression échouent et le pipeline réel
process_expired_channel_bans ne retire aucun ban pourtant arrivé à échéance.
Cette reproduction ne mesure pas toutes les possibilités d'auto-reconnexion
du pilote MariaDB ; elle démontre que le helper ne suit pas le propriétaire.

## Correction limitée au helper de stockage

- Un résolveur privé _current_dbh utilise le propriétaire db déjà présent dans
  le bot et sa méthode existante ensure_connected.
- Les cinq gardes SQL le consultent : active_ban_for_mask, add_ban,
  list_active_bans, mark_removed et expired_bans.
- Le handle est remplacé même lorsque ensure_connected renvoie undef. Un ancien
  handle, y compris encore vivant, ne sert pas de connexion de secours quand
  le propriétaire n'en confirme aucune.
- Une opération suivante consulte de nouveau le propriétaire même après cet
  effacement : le même objet reprend après rétablissement.
- Sans propriétaire compatible, les appels autonomes avec dbh restent inchangés.
  Le constructeur et le câblage du démarrage conservent leur API actuelle.

Les requêtes/binds, niveaux, masques, durées, horloge SQL d'expiration, limites,
sélection du ban récent, retours et messages d'erreur existants sont conservés.
Le keepalive principal ne change pas et aucun timer ni retry SQL supplémentaire
n'est ajouté. La reconnexion passe par la politique existante de Mediabot::DB.
Aucun schéma, migration, fichier SQL, configuration privée, VERSION ou autre
module de production n'est modifié.

En cas d'indisponibilité, les méthodes gardent leurs retours historiques :
undef ou liste vide pour les lectures, erreur 'no database handle' pour les
écritures. Ce round ne redéfinit pas la réaction des appelants de modération
à une panne SQL et ne garantit pas l'application d'un ban sans base disponible.

## Régression et compatibilité

Le cas 69 existant conserve ses 32 critères et reçoit cinq assertions regroupées.
Un enfant Perl exécute les vrais helpers, le vrai ensure_connected, puis le
vrai pipeline d'expiration. Les sorties IRC sont interceptées. Aucun serveur
IRC ou MariaDB public n'est contacté.

Les bases DBI/SQLite privées comprennent des bans actif/expiré/futur/permanent,
un ban déjà retiré, deux canaux et des ids non consécutifs. Un RootClass de
test enregistre les SQL/binds originaux et délègue aux vrais statements.
Le seul pont de dialecte traduit NOW() + INTERVAL ? SECOND vers datetime
SQLite ; une fonction NOW privée fixe l'horloge de test, sans attente réelle.

Dix appels nominaux (cinq opérations avec propriétaire, cinq avec dbh seul)
conservent des traces JSON complètes identiques avant/après : résultats,
requêtes/binds, toutes les lignes, avertissements et nombre de connexions.
Dix appels après reconnexion, déclenchée par le bot ou par le helper lui-même,
retrouvent ces résultats et traces SQL, avec exactement une reconnexion.

L'indisponibilité est vérifiée sur les cinq méthodes : handle effacé, aucun
SQL tenté sur l'ancien handle et contrat de retour conservé. Un autre scénario
garde volontairement un ancien handle vivant tandis que le propriétaire est
indisponible : la suppression est refusée et la ligne reste active.

Enfin, le même objet traverse panne et reprise, puis le pipeline natif
d'expiration retire le seul ban dû, envoie un unique MODE -b, marque la ligne
avec system/expired et incrémente une fois sa métrique. Le ban futur, le ban
permanent d'un autre canal et le ban déjà retiré conservent leur état.

Le cas étendu donne 34/37 sur la source et 37/37 après correction. Huit mutations
indépendantes sont détectées ; les 32 critères historiques passent dans chaque
mutant. Aucun nouveau cas numéroté ou fixture partagé : les 1 156 cas restent.
QUALIFICATION.md du paquet détaille les suites complètes et les limites locales.
