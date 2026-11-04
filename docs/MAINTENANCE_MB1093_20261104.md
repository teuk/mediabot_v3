# MB1093 — Protections karma cohérentes et remise à zéro ciblée

## Source

Snapshot snap_mediabot_v3_teuk_20261104_093612.zip.
VERSION3.8dev-20261104_083459 ; MB1092 r2 présent et ses443 contenus
qualifiés retrouvés à l’identique. Cinq chemins : Karma.pm,
Partyline/Commands.pm, cas390 existant, changelog et cette note.

## Défauts reproduits

Le cache de salons utilise lc(channel), mais le cooldown karma utilisait
l’orthographe reçue, et la fenêtre anti-brigade l’incorporait dans sa clé.
Alice pouvait donc voter sur #TeSt puis immédiatement sur #test. De même,
six personnes réparties entre différentes casses évitaient le seuil commun.
Les deux protections utilisent maintenant la clé canonique du cache.

La commande .flushcooldown Alice #test cherchait alice:#test dans un tableau
qui contient des clés alice:bob, alice:carol, etc. Elle ne libérait donc pas
les votes d’Alice. Elle retire maintenant les réservations dont le donneur
est exactement Alice, sur le seul salon demandé. Alan, Alice2 et les autres
salons restent indépendants. L’anti-brigade n’est pas réinitialisée par cette
commande, dont la fonction reste le cooldown individuel.

Enfin, toute syntaxe non reconnue tombait dans la branche de remise à zéro
globale. Une simple faute de frappe pouvait lever les protections partout.
Seule la commande sans argument autorise maintenant ce reset global ; une
syntaxe invalide affiche l’usage et conserve l’état.

## Utilisation partyline

- .flushcooldown Alice #i/o : libérer les votes d’Alice sur ce salon.
- .flushcooldown #i/o : libérer les cooldowns de ce salon.
- .flushcooldown : libérer explicitement tous les cooldowns karma.

La casse du salon et du donneur n’affecte plus la sélection. Les préfixes IRC
# & ! + sont acceptés dans la portée opérateur. Les messages conservent
l’orthographe du salon saisie par l’opérateur.

Les règles restent30 secondes par couple donneur/destinataire, plus de cinq
votants distincts en30 secondes pour l’anti-brigade, un seul avertissement,
et trois votes maximum par message. Échec SQL, métriques, historique stocké,
achievements et affichage des votes suivent les chemins existants. Aucun
schéma, donnée, configuration, VERSION, radio, YouTube ou README modifié.

## Validation et livraison

Le cas390 n’imite plus une version de l’algorithme : il appelle les vrais
handlers automatiques/explicites, le dispatcher partyline et une DB SQLite
privée. Le pont ne traduit que la syntaxe MariaDB. Les huit scénarios échouent
sur le code initial, puis passent sur le code corrigé. Ils vérifient les votes
réellement stockés, leur historique, les refus, les autres salons/voteurs,
l’expiration et les trois portées de reset. Aucun sleep, nouveau fichier de
test ou processus de test ajouté. Treize assertions recopiées sont remplacées
par huit vérifications groupées. Résultats détaillés dans QUALIFICATION.md.

Le paquet conserve le périmètre cumulé et les suppressions déjà qualifiés.
Modop : intégrité, aperçu, application idempotente, full --progress avec ETA,
audits, inventaire, dev seul avec attente d’un nouveau PID stable dix secondes,
puis commit.sh --skip-preflight interactif, VERSION3.8dev automatique.
Aucun contrôle WorkingDirectory n’est imposé. Un PID stable ne prouve pas IRC.
