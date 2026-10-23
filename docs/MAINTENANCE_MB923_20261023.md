# MB923 — Login : supprimer le double comptage d'une même identité

Date : 2026-10-23. Base : snap_mediabot_v3_teuk_20261023_120453.zip.

## Défaut reproduit

userLogin_ctx limite les échecs sur le pseudo IRC et sur le compte demandé.
Les clés sont mises en minuscules. Lorsque les deux noms sont identiques,
éventuellement avec une casse différente, chaque branche d'échec incrémentait
deux fois la même entrée. Trois mauvais essais donnaient un compteur de 6 et
le quatrième était bloqué, alors que la limite explicite est de cinq échecs.
Un compte inconnu avec le même nom que le pseudo provoquait le même défaut.

La sonde native reproduit aussi un effet visible : après trois mauvais mots
de passe, un mot de passe correct au quatrième essai était bloqué. Après
correction, la vérification réussit, la session est enregistrée et les
compteurs du pseudo et du compte sont remis à zéro.

## Correction limitée à userLogin_ctx

Après la validation des arguments et le retrait éventuel du pseudo injecté,
la fonction prépare une liste unique des deux clés après leur normalisation
existante en minuscules. La garde de limitation, la branche utilisateur inconnu
et la branche mauvais mot de passe parcourent cette liste.

Deux identités distinctes gardent leurs deux compteurs. Une identité commune
n'est comptée qu'une fois. La limite reste cinq échecs sur une fenêtre de
60 secondes ; les requêtes suivantes sont bloquées avant tout accès SQL.
La remise à zéro au succès, le nettoyage périodique et les textes de réponse
gardent leur fonctionnement actuel.

Aucun schéma, migration, requête/bind, format de mot de passe, état persistant,
autorisation, configuration privée, VERSION ou autre module ne change.
Le partage historique de l'espace des clés entre pseudo et compte reste :
ce round supprime les doublons dans un appel, sans changer cette structure.

## Vérifications natives

Le cas 165 existant conserve ses six critères et reçoit cinq assertions
regroupées. Un enfant Perl exécute le vrai userLogin_ctx et le vrai
Mediabot::Auth::verify_credentials sur DBI/SQLite privé. Les statements
originaux s'exécutent sans traduction de dialecte ; une fonction NOW privée
fournit une date fixe. Une horloge propre à l'enfant permet de tester les
secondes 59 et 60 sans attente. Aucune horloge de production n'est modifiée.
Les messages IRC et journaux de commande sont interceptés.

Les cas couvrent :

- pseudo et compte égaux, casse différente et utilisateur inconnu : compteurs
  1/2/3/4/5, puis blocage du sixième essai sans SELECT ni vérification SQL ;
- deux identités distinctes, rotation des pseudos vers un compte et rotation
  des comptes depuis un pseudo : les deux protections conservent leur effet ;
- blocage à 59 secondes et premier nouvel échec à exactement 60 secondes ;
- vraie connexion réussie après trois échecs, succès nominal, forme préfixée,
  session live, auth en base, hostmask, reset des compteurs et nettoyage ;
- arguments undef, scalaire, hash, liste vide, mot de passe absent ou vide :
  syntaxe privée et aucun accès SQL.

Les 30 observations natives hors correction sont identiques avant/après :
retours, sorties, compteurs, métriques, sessions, SQL/binds et lignes persistantes.
Les seuls binds non comparés littéralement sont les nouveaux hashes bcrypt à
sel aléatoire : ils sont vérifiés par la vraie fonction password_matches puis
normalisés dans la trace de test. Le hash réel reste envoyé à SQLite.

Le cas étendu donne 8/11 sur la source et 11/11 après correction. Huit mutations
indépendantes sont détectées par les nouveaux critères ; les six anciens
passent dans chaque mutant. Aucun nouveau cas numéroté ou fixture partagé :
le catalogue conserve ses 1 156 fichiers. QUALIFICATION.md du paquet détaille
les suites complètes, l'installateur et les limites locales.
