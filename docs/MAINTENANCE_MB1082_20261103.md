# MB1082 — Préparer une commande avant de modifier le registre

Base : snap_mediabot_v3_teuk_20261103_113944.zip.
VERSION : 3.8dev-20261103_103839. Les 409 chemins précédemment qualifiés
correspondent exactement à MB1081 final ; les correctifs antérieurs sont conservés.

## Défauts

CommandRegistry::register_command vérifiait les conflits, supprimait les
anciens alias lors d'un remplacement, puis construisait l'entrée à publier.
Cette construction copie le hash de métadonnées fourni par l'appelant.
Un hash Perl tied est accepté comme HASH et son énumération/lecture peut lever.
La commande canonique restait alors ancienne, mais ses alias avaient déjà
été supprimés. Un échec de remplacement n'était donc pas atomique.

La copie pouvait aussi réentrer dans le registre et y enregistrer une commande
ou un alias concurrent. Comme les conflits avaient été validés avant cette
copie, l'appel externe publiait ensuite son alias sans revoir le nouvel état :
il pouvait détourner l'alias concurrent ou masquer une nouvelle commande
canonique. Ce sont des cas d'API native/plugin, pas une entrée IRC textuelle.

## Correction et limites

La construction complète de l'entrée est déplacée avant toute validation ou
modification des maps live. Elle reste une copie superficielle des métadonnées,
avec la même structure et les mêmes champs. L'énumération et le FETCH des
données appelantes ont donc lieu avant le début de la publication.

Les contrôles de conflits inspectent ensuite le namespace courant, y compris
les modifications réalisées par un éventuel callback réentrant. Après leur
réussite seulement, les anciens alias de cette commande sont retirés puis
l'entrée et ses nouveaux alias sont publiés. Aucun travail de copie de données
appelantes n'est ajouté à cette dernière phase.

Une exception pendant la copie est propagée telle quelle, y compris un objet,
sans supprimer les alias de l'ancienne commande. Une inscription réentrante
réussie reste conservée ; si elle occupe un nom demandé par l'appel externe,
ce dernier échoue sur le conflit courant. Une telle inscription ne se fait
pas annuler par l'échec de l'appel externe.

Il ne s'agit pas d'une transaction sur le code du plugin : les effets de bord
que celui-ci effectue volontairement pendant une lecture ne sont pas annulés.
L'ordre d'évaluation change : la lecture des métadonnées peut maintenant
précéder un refus de conflit. Les références imbriquées restent partagées
comme dans la copie superficielle historique. Il n'y a ni deep clone, nouvelle
API, nouveau handler, changement d'ACL ou changement de syntaxe de commande.
Les autres méthodes du registre restent identiques octet pour octet.

## Tests natifs

Le cas 445 conserve son exécution native dans le runner existant. Il utilise
un vrai hash tied pour déclencher FIRSTKEY, NEXTKEY et FETCH ; aucun algorithme
de registre n'est simulé. Les observations passent par list, count,
command_for, aliases_for, handler_for et l'identité des entrées retournées.

Les anciennes conditions de conflits d'alias/nom canonique et de remplacement
réussi sont regroupées en trois comparaisons. Deux pins de source redondants
(marqueur et absence de shell) sont retirés ; l'audit sécurité reste exigé.
Quatre groupes supplémentaires couvrent :

- échec à chacun des trois stades de copie, inscription/remplacement et
  sources public/private : exception d'origine, ancienne entrée, alias,
  handlers, métadonnées et namespace conservés ;
- inscription réentrante d'un alias concurrent, sur les mêmes deux sources
  et les deux formes d'appel : l'inscription indépendante reste intacte ;
- inscription réentrante d'un nom canonique concurrent, mêmes garanties ;
- copie tied réussie une seule fois, détachement des valeurs de premier
  niveau, références imbriquées partagées, champs, normalisation, alias et
  isolation public/private conservés.

Les trois groupes de panne/réentrance échouent sur le module intact (4/7),
puis passent corrigés (7/7). Le cas original comptait 15 assertions ; le nouveau
en compte sept, soit huit de moins. Aucun nouveau cas, processus, attente ou
accès réseau. QUALIFICATION.md donne les résultats et limites locaux.

## Exploitation

Quatre chemins changent : CommandRegistry, cas 445, changelog et cette note.
Pas de schéma, dépendance, configuration ou donnée persistante à modifier.
VERSION, README racine, commit.sh privé, runner/ETA, radio, YouTube et correctifs
précédents sont conservés.

Le paquet contrôle les contenus exacts avant/après et les changements qualifiés
en attente. Full visible --progress/ETA sans redirection, audits sécurité/startup,
inventaire et whitespace avant staging/restart. Après réussite complète : dev
seul, nouveau PID stable dix secondes, commit.sh natif --skip-preflight et VERSION
3.8dev automatique. Un PID stable ne prouve pas la reconnexion IRC.
