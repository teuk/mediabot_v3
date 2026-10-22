# MB917 — Contexte de livraison des réponses Gemini

## Défaut reproduit

La commande publique Gemini vérifiait son chanset au lancement, puis acceptait
le résultat asynchrone sans revalider la connexion ni l'appartenance au canal.
Une réponse, une erreur provider ou une erreur de réponse vide pouvait ainsi
être remise aux helpers après un départ/rejoin, une reconnexion ou la révocation
de +Gemini. Une seconde ligne déjà dans PacedOutput avait le même problème.

## Mise en commun et correction

`Mediabot::IRC::DeliveryContext` extrait à l'identique les deux fonctions MB840
qui existaient dans CommandAsync. `capture_delivery_context($bot, $channel)`
retient le transport et, si le runtime de canaux est présent, sa génération.
`delivery_context_current($bot, $binding)` vérifie l'arrêt du bot, l'identité et
la connexion du transport, l'identité du runtime et la génération du canal.
Les deux anciens points d'entrée de CommandAsync restent des trampolines goto.
Le mode sans transport des fixtures conserve sa sémantique ; il n'est pas lié
rétroactivement à une connexion apparue après le lancement.

Gemini capture ce contexte au lancement. Au retour du provider, un contexte
périmé ou un chanset absent/illisible empêche la livraison, y compris celle des
erreurs. La garde inflight est toujours libérée et les callbacks doublons restent
inertes. Le provider n'est pas annulé : son travail peut terminer normalement.

`queue_privmsg_chunks` accepte un sixième argument optionnel
`{ can_send => sub { ... } }`. Ce prédicat est vérifié avant chaque ligne,
y compris sans timer ou avec un délai nul. Faux ou exception supprime seulement
le reste du lot concerné ; les lots suivants gardent leur ordre et le délai de
frontière existant. Gemini fournit ce prédicat pour revérifier le contexte et
+Gemini entre ses lignes. Les autres appelants ne sont pas migrés implicitement.
Les vérifications du chanset utilisent les fonctions existantes ; elles ajoutent
une relecture au retour et avant chaque ligne Gemini encore en attente.

La frontière est la remise aux helpers. Une ligne déjà acceptée par Helpers ou
sa file AntiFlood distincte n'est pas rappelée par cette correction. Le module
partagé ne crée pas une autorisation universelle : chaque appelant conserve sa
propre politique. Aucune mutation de schéma de base de données n'est nécessaire.

## Non-régression et périmètre

Les 19 assertions initiales du cas 1029 restent ; neuf critères regroupent 52
scénarios dans un sous-processus avec de vraies boucles/timers IO::Async et le
vrai ConversationRuntimeState. Les frontières provider, configuration/chanset
et sorties terminales sont substituées, sans API, SQL ou IRC réel.

Les contrôles couvrent succès Unicode sur deux lignes, erreurs, réponse vide,
callback doublon, remplacement/déconnexion du transport, arrêt, départ/rejoin,
reconnexion, remplacement du runtime, changement CASEMAPPING, désactivation et
échec de lecture du chanset. Ils vérifient aussi la survie d'un lot indépendant,
d'une nouvelle réponse Gemini et le nettoyage de la file et des timers.

Le cas 891 de présentation du runner vérifie désormais un compte positif de
réussites égal au total au lieu de figer le probe Gemini à 19 assertions.
Les 1 156 cas sont conservés ; aucun fichier de fixture ni cas numéroté ajouté.

Une comparaison distincte retrouve les mêmes 72 traces d'envoi nominales et
40 décisions des anciennes fonctions CommandAsync. Une sonde supplémentaire
traverse les vrais Helpers/Output/Sender, le formatage UTF-8, NoColors, badword,
l'historique et les métriques, en substituant la socket finale et le backend SQL.
Les trois parcours nominaux sont identiques ; deux queues révoquées arrêtent
leur seconde ligne sans métrique ni historique pour cette ligne.

Le validateur du paquet conserve six syntaxes, deux groupes ciblés, toute la
suite sans filtre, les 37 invariants de sécurité et l'intégrité de démarrage.
Les résultats et limites locaux sont consignés dans QUALIFICATION.md.
Aucun schéma SQL, configuration privée, VERSION, plugin, Partyline, radio,
service, runner ou audit n'est modifié. Aucun déploiement ou redémarrage automatique.
