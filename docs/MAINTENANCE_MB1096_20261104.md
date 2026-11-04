# MB1096 — Vocabulaire Unicode pour !compat

Source : snap_mediabot_v3_teuk_20261104_122852.zip.
VERSION observée : 3.8dev-20261104_112001 ; MB1095 présent.

## Défaut et correction

!compat conserve les 100 mots les plus fréquents de chaque participant, puis
calcule leur intersection et leur union pour la composante vocabulaire sur
30 points. Le découpage historique conservait les octets 0x80 à 0xFF comme
des lettres. Il pouvait compter des emojis UTF-8 comme des mots, compter la
longueur en octets, perdre des lettres au-delà de U+00FF dans du texte décodé
et séparer des formes Unicode canoniquement équivalentes.

Le comptage utilise maintenant decode_irc_text, la frontière existante qui
décode une fois le UTF-8 valide sans modifier l’entrée et conserve les octets
hérités non UTF-8. NFC réunit les accents canoniques, puis la conversion en
minuscules porte sur les caractères. Un mot commence par une lettre, un
chiffre ou un underscore et peut contenir leurs marques combinatoires.
Les autres caractères, dont ponctuation et emoji, séparent les mots.

Le minimum est toujours de quatre caractères, désormais après normalisation.
Les accents ne sont pas supprimés : café et cafe restent deux mots différents.
Les mots trop courts et les emojis seuls ne donnent pas de points de vocabulaire.

Le tri par fréquence, le départage lexical des égalités, les 100 mots retenus,
les limites et requêtes SQL, le Jaccard, les composantes heures/karma/co-présence,
les réponses IRC et les compteurs restent en place. Seule la collecte des clés
de vocabulaire dans Stats/Affinity.pm change.

## Tests utiles

Le cas 1398 garde ses six assertions d’origine : plusieurs graines Perl,
ordre inversé, priorité de fréquence, limite de 100 mots, petit/vide,
score final, composante heures, cibles, audit et compteur.

Le même probe passe maintenant par une base SQLite privée : les mêmes TEXT
sont relus avec sqlite_unicode activé ou désactivé, et le repli latin1 passe
par un BLOB. Il couvre accents majuscules/minuscules, formes composées et
décomposées, œ, cyrillique, japonais, tirets Unicode, emojis, mots courts et
accents distincts. Les flags DBI observés sont contrôlés avec les scores et
l’absence de warnings ou d’échec du handler. Quatre graines exécutent chacune
24 invocations du vrai handler, soit 96 au total, dans quatre sous-processus.

Les 14 anciens sous-processus sont regroupés en quatre. Deux assertions
natives groupées remplacent les deux anciens pins de tokenizer compat dans
le cas 642 ; ses contrôles mood et accents historiques restent présents.
Le pin de tokenizer compat du cas archive 764 est aussi retiré ; ses autres
contrôles d’archive sont conservés. Au total, une assertion de moins, sans
nouveau fichier, délai,
dépendance ou accès externe dans les tests.

## Application sur le dev

Le script vérifie le périmètre et les empreintes du snapshot, applique le
patch ou reconnaît son application exacte, puis lance les ciblés, la full
suite visible en --progress avec ETA, les audits et l’inventaire. Après
réussite, seul mediabot@dev.service est redémarré, avec attente d’un nouveau
PID actif et dix secondes de stabilité. Un échec bloque l’appel au commit.
Un PID stable ne prouve pas la reconnexion IRC.

Le commit passe par commit.sh --skip-preflight interactif ; VERSION reste
3.8dev automatique. Si demandé, saisir KEEP DELETIONS pour conserver les
suppressions précédemment qualifiées, puis confirmer le commit.

Aucun schéma, donnée utilisateur, configuration, README racine, commit.sh
privé, radio ou YouTube modifié. La préparation locale ne redémarre aucun
service et ne commit/push rien sur le dépôt utilisateur.
