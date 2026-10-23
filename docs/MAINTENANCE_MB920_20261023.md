# MB920 — Jeux : frontières Unicode sans changer les entrées legacy

Date : 2026-10-23. Base : `snap_mediabot_v3_teuk_20261023_104718.zip`.

## Défaut reproduit

Le cœur IRC appelle déjà `Helpers::decode_irc_text` sur les messages publics
avant `checkTriviaAnswer` et `checkQuotegameAnswer`. Les jeux bornaient pourtant
les réponses avec des classes limitées à ASCII et aux valeurs 0x80–0xFF,
conçues pour d'anciens appels en octets UTF-8. Une lettre décodée au-delà de
U+00FF était donc traitée comme un séparateur.

Exemples : la réponse `on` était acceptée dans `Āon` ou `onœ` ; la réponse
cyrillique `да` était acceptée dans `подарок`. Le même défaut concernait les
nombres d'autres écritures et les marques combinatoires. Dans le quotegame,
le masquage utilisait la même classe : avec l'auteur `on`, le mot `Āon`
était affiché `Ā???` au lieu de rester entier.

Les essais natifs montrent 48 fausses victoires (12 exemples × deux jeux ×
texte caractère/texte passé par le vrai décodeur entrant) avant correction,
et aucune de ces fausses victoires ensuite. Les 24 masquages correspondants
préservent maintenant le mot et masquent uniquement la mention séparée de l'auteur.

## Correction

Trois expressions dans UserCommands.pm ajoutent les propriétés Unicode
`\p{L}` (lettres), `\p{N}` (nombres) et `\p{M}` (marques combinatoires)
aux classes existantes : validation trivia, masquage et validation quotegame.
Les lettres du plan supplémentaire sont couvertes aussi.

Le préfixe ASCII et la plage historique 0x80–0xFF restent. Les caractères spéciaux
des nicks IRC dans le quotegame restent également. Aucun décodage supplémentaire,
normalisation canonique, changement de casse, nouvelle règle d'identité IRC ou
modification du texte original n'est introduit. Les règles de ponctuation
existantes restent : un tiret cadratin ou un emoji autour d'une réponse décodée
reste un séparateur ; les mêmes octets UTF-8 non décodés gardent leur comportement
historique plus conservateur. Le correctif ne transforme pas ce mode legacy.

Une réponse rejetée n'arrête pas la manche, ne donne aucun point et laisse le
timer du quotegame actif. Les bonnes réponses gardent leurs messages, compteurs,
écritures et annulation de timer. Les délais, indices, scores, SQL/binds, sorties
IRC et hooks ne sont pas remaniés.

## Tests et limites

Le cas 658 existant passe de neuf à quatorze critères : cinq nouvelles assertions
regroupées exécutent les vrais points d'entrée des jeux et le vrai décodeur
entrant, sur DBI/SQLite privé et de vrais timers IO::Async. La création de partie
quotegame utilise le vrai SELECT : SQLite reçoit uniquement une fonction RAND de
fixture ; un pont privé traduit l'upsert trivia MariaDB et NOW vers SQLite.
Les sorties IRC, métriques et logger sont capturés. Aucun serveur SQL ou IRC réel.

Les 18 vecteurs (12 inclus dans un mot, six réponses délimitées) sont parcourus
en caractères, via le décodeur IRC et en octets, pour chaque validation et le
masquage : **162 exécutions natives**. Les catégories incluent Latin étendu,
cyrillique, CJK, nombres, marques combinatoires et lettre hors du premier plan.
Les résultats vérifient scores mémoire/SQL, métriques, messages et timer.

Le cas étendu donne **11/14 sur la source, 14/14 sur le candidat**. Les cas 559,
658 et 660 gardent leurs 32 critères historiques et leurs vecteurs en octets ;
trois scans de câblage acceptent maintenant les propriétés ajoutées après la
plage historique. Les nouveaux critères testent le comportement réel, pas une
copie du prédicat. Aucun nouveau module, fixture partagé ou fichier de cas.

Une comparaison source/candidat de 90 exécutions hors défaut conserve exactement
les résultats, messages et octets de sortie, SQL/binds des validations, scores,
métriques et présence du timer : 54 combinaisons nominales et 36 combinaisons
en octets sur les réponses incluses dans un mot. Les 72 autres exécutions portent
les comportements volontairement corrigés : 48 validations et 24 masquages.

Six mutations indépendantes sont détectées par les nouveaux critères, tandis
que les 32 critères historiques continuent de passer : omettre chacun des trois
points de correction, ou omettre séparément L, N ou M.

Le catalogue reste à 1 156 fichiers. Aucun schéma, migration, fichier SQL de
production, configuration privée, VERSION, module partagé IRC, plugin ou Partyline
ne change. Le détail des suites complètes et des limites locales MB786/MB647 figurent
dans QUALIFICATION.md du paquet. Le validateur livré exige toujours la suite
complète sans filtre, l'audit et l'intégrité de démarrage.
