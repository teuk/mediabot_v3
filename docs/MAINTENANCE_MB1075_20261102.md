# MB1075 — Propriété et révocation des minuteurs de scripts

Base : snap_mediabot_v3_teuk_20261102_144557.zip.
VERSION : 3.8dev-20261102_134544. Les 386 chemins précédemment qualifiés
correspondent à MB1074 final ; ils sont conservés.

## Défaut reproduit

Un countdown supprimé de la boucle peut rester référencé par un appelant ou
avoir un rappel déjà retenu. L'ancien callback utilisait seulement son nom,
effaçait la table active sans comparer l'occurrence et libérait ce nom sur le
runner courant du bot. Après annulation puis réarmement du même nom, ce rappel
pouvait exécuter l'ancien script et supprimer les métadonnées/le slot du nouveau.

La table était publiée après start(). Une expiration réentrante pendant
l'armement pouvait donc être suivie de la publication d'un timer fantôme. Si
un nouveau timer du même nom était armé pendant cette expiration, puis que
l'ancien start échouait, le rollback du runner effaçait aussi son nouveau slot.

## Implémentation

Chaque réservation du runner est un jeton de référence distinct. Le callback
schedule_timer garde ses deux arguments action/contexte. Le getter interne
_timer_reservation permet au bridge de capturer ce jeton ; release_timer(name)
reste compatible et release_timer(name, expected) ne retire que le slot attendu.
Le rollback d'un armement échoué possède son propre jeton.

Le bridge publie son record avant new/add/start. À l'expiration, il compare
l'identité du record actif et celle du timer natif ; il révoque le record et
la réservation d'origine avant cleanup ou exécution du script. Un callback
retenu d'une ancienne occurrence devient inerte. Le cleanup d'un échec ne
retire que son propre record et son timer provisoire. Une expiration inline
n'est pas republiée après start.

Le record conserve le runner et la boucle d'origine par références faibles.
Le callback ne retient fortement ni le plugin, ni son record, ni la boucle.
Après révocation, garder le timer natif ne garde plus le payload du script.
Un changement de runner ne redirige pas la libération vers le nouveau runner.

La liste partyline reste une projection détachée des champs publics : pas de
jeton ou payload exposé. Le corps de _fire_script_timer est inchangé : mêmes
portes enabled/apply/IRC/scope, script et contexte, profondeur et refus des
chaînes. Plafonds, délais, noms, protocole des scripts et métriques conservés.
Les vieux records/hash ou timers nus et slots scalaires restent annulables.
Les closures déjà créées par l'ancien code ne sont pas réécrites lors d'un
reload ; le restart dev prévu recrée les callbacks.

## Tests

Le fichier 725 existant conserve les gardes de politique et son vrai aller-retour
script exécutable Perl + boucle IO::Async, ainsi que l'annulation unregister.
Les anciens pins de source et les répétitions documentaires sont remplacés par
huit assertions de cycle de vie : annulation/réutilisation du nom et rappel
répété ; échecs constructeur/add/start après ajout/armement réel ; expiration
inline ; expiration puis successeur réentrant et échec de l'ancien start ;
remplacement du runner ; libération du payload/plugin/boucle malgré un timer
retenu ; annulation en lot ; annulation du format historique.

Les tests utilisent les vrais Countdown et Loop. L'injection d'erreur appelle
le code natif avant d'échouer pour add/start ; l'exécution différée est observée
à sa couture dédiée, en complément du vrai script du test historique. Les
attentes et le nombre de fichiers n'augmentent pas. Soixante assertions dans
725 contre soixante-neuf auparavant : neuf de moins.

QUALIFICATION.md dans le paquet fournit les nombres réellement mesurés, la
contre-épreuve sur snapshot intact et les éventuelles limites d'environnement.
La full serveur reste obligatoire et visible en --progress avec son ETA.

## Exploitation

Aucun schéma, import, donnée persistante, dépendance ou configuration modifié.
VERSION, README racine, commit.sh privé, runner/ETA, radio, YouTube, jeux de
hasard et correctifs antérieurs restent inchangés.

Le paquet vérifie les états exacts avant/après et les changements précédents
qualifiés encore en attente. Full visible, audits sécurité/startup, inventaire
et whitespace avant staging/restart. Puis dev seul, nouveau PID stable dix
secondes, commit.sh natif interactif --skip-preflight, VERSION 3.8dev automatique.
Le PID stable ne prouve pas la reconnexion IRC. Aucun test n'est contourné.
