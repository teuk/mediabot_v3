# MB1081 — Libérer les countdowns IRC retirés avant expiration

Base : snap_mediabot_v3_teuk_20261103_100539.zip.
VERSION : 3.8dev-20261103_090526. Les 406 chemins précédemment qualifiés
correspondent exactement à MB1080 final ; les correctifs antérieurs sont conservés.

## Défaut

Le helper IRC::Timer possède un callback qui capture sa variable timer, et
le notifier possède ce callback. Le chemin d'expiration rompt explicitement
ce cycle. Mais un stop/remove anticipé, suivi de la libération des propriétaires
externes, ne passe pas par l'expiration. La référence forte capturée conserve
alors le notifier, son callback, le payload et la boucle.

Le défaut est reproduit avec une vraie boucle IO::Async, un délai d'une heure
qui n'est pas attendu, et des sondes faibles : zéro notifier dans la boucle,
mais le timer et le payload restent vivants sur le module intact.

Un second cas concerne l'expiration pendant start. Le callback nettoie le
notifier et efface son cleanup. Si start ou le callback utilisateur lève ensuite,
le handler de setup tentait d'appeler ce cleanup effacé et masquait l'exception
d'origine par une erreur de coderef indéfini.

## Correction et limites

La référence du notifier capturée par le callback devient faible. Une référence
forte séparée le garde vivant pendant le setup et la préparation du retour.
Le callback ne capture pas ce propriétaire temporaire. Après retour, la boucle
et l'appelant gardent leurs propriétaires normaux ; le helper n'ajoute plus
son propre cycle timer/callback. À l'expiration, l'ordre stop/remove puis
callback, la libération du payload, les arguments et la garde single-use restent
les mêmes. IO::Async reste chargé à la demande.

Le handler d'échec ne rappelle le cleanup que s'il existe encore. Si une
expiration inline l'a déjà effectué, l'exception d'origine est propagée telle
quelle, y compris un objet exception. Les échecs ordinaires de construction,
add et start conservent leur cleanup et leur propagation historiques.

Il n'y a pas de nouvelle API de cancel et le notifier reste single-use.
Un stop seul n'est pas une révocation du callback. Une référence externe au
callback peut encore posséder son payload ; un callback utilisateur qui
capture lui-même le notifier peut créer son propre cycle. Ces propriétaires
doivent toujours gérer leur durée de vie et leur politique de révocation.
Une boucle qui refuse remove ne garantit toujours pas la libération du notifier.
Le correctif vise le cycle propre au helper, sans réécrire les files appelantes.

## Tests natifs

Le cas 1311 conserve les vraies boucles et notifiers IO::Async. Les conditions
de l'expiration normale et des échecs add/start sont regroupées : propriété
du loop, libération timer/payload, identité d'exception et callback tardif inerte.
Le scénario NOTICE avec exception de transport puis reprise est conservé.
Le batch PRIVMSG conserve son ordre, son nettoyage de file et de notifier.

Deux nouveaux groupes couvrent :

- 24 créations avec délai d'une heure, stop/remove avant expiration et
  libération des propriétaires : notifier, payload et boucle libérés sans
  exécuter le callback utilisateur ; aucune attente du délai ;
- expiration pendant le start natif, avec retour normal ou exception juste
  après le callback : un seul appel, nettoyage complet, retour historique
  undef si déjà expiré, identité de l'objet exception préservée.

Les deux groupes échouent sur le module intact (13/15), puis réussissent
corrigés (15/15). Le timer et la boucle sont natifs ; seule l'entrée dans
l'expiration pendant start est provoquée par un seam local pour tester ce bord.

Le stress AntiFlood alternant PRIVMSG/ACTION passe de 50 à six tours : trois
paires suffisent aux mêmes transitions fonctionnelles. Les bornes de notifier
sont vérifiées à chaque tour, puis le nombre/ordre/enveloppes et l'arm final
dans une comparaison complète. Les tours supplémentaires étaient répétitifs.
Les nouvelles 24 suppressions ciblent la fuite effectivement corrigée.
128 -> 15 assertions : 113 de moins. Aucun nouveau cas, processus ou attente.
QUALIFICATION.md donne les mesures réelles et limites de la full locale.

## Exploitation

Quatre chemins changent : helper Timer, cas 1311, changelog et cette note.
Pas de schéma, dépendance, configuration ou donnée persistante à modifier.
VERSION, README racine, commit.sh privé, runner/ETA, radio, YouTube et correctifs
précédents sont conservés. Le restart dev renouvelle les callbacks ; le patch
ne répare pas les cycles des notifiers déjà créés par un ancien code.

Le paquet contrôle les contenus exacts avant/après et les changements qualifiés
en attente. Full visible --progress/ETA sans redirection, audits sécurité/startup,
inventaire et whitespace avant staging/restart. Après réussite complète : dev
seul, nouveau PID stable dix secondes, commit.sh natif --skip-preflight et VERSION
3.8dev automatique. Un PID stable ne prouve pas la reconnexion IRC.
