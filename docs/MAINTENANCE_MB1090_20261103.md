# MB1090 — Dépouillement partagé et expiration cohérente des sondages

## Source et périmètre

Snapshot snap_mediabot_v3_teuk_20261103_205222.zip, MB1089 présent,
VERSION 3.8dev-20261103_192348. Quatre chemins : CommunityState.pm,
cas natif528, CHANGELOG et cette note. Aucun changement de schéma, donnée,
configuration, dépendance, commande ou VERSION. DDG, Wikipédia, radio,
YouTube, README racine et commit.sh privé restent inchangés.

## Défaut et comportement

L'expiration des sondages est paresseuse. vote/unvote la vérifiaient, mais
pollstatus continuait d'afficher des résultats actifs après l'échéance et
pollresult pouvait encore annoncer Active. Les vues de lecture observent
maintenant la même condition stricte now > deadline. À la seconde exacte de
l'échéance, le sondage reste admissible comme avant.

pollstatus annonce l'expiration une seule fois puis le sondage est fermé.
pollresult affiche directement Closed et le dépouillement final, sans ajouter
une ligne d'expiration. Les bulletins, autres salons et métriques d'expiration
existantes ne changent pas. Une clôture déjà observée interdit une extension ;
une extension explicite avant cette observation peut toujours reprendre une
échéance passée à partir de maintenant, comme le contrat MB431 existant.

## Implémentation

Un helper interne _poll_tally calcule compte de votants, scores, total des
scores et tous les gagnants dans l'ordre des options. vote, status, result et
stop partagent ce calcul. Les anciens vote/status reparcouraient l'ensemble
des bulletins pour chaque option, parfois deux fois en mode pondéré. Le coût
passe de O(votants × options) à O(votants + options). Les autres vues cessent
également de dupliquer le choix des gagnants.

Les libellés et formats existants restent préservés, y compris l'arrondi
historique des résultats et le pourcentage entier des vues live/stop. Poids
absent =1 ; aucun gagnant inventé quand personne n'a voté. Autorisation Master
pour la clôture, métrique de durée et compteurs existants restent exécutés.
Aucun cache de dépouillement : revote et retrait sont reflétés immédiatement.

## Tests

Le cas528 existant passe de14 vérifications de source/algorithme recopié à
huit groupes exécutant les vrais handlers et Context, via module et façade.
Ils couvrent les quatre vues, pondération, égalités, poids manquants, zéro vote,
expiration observée par les lectures, limite exacte, extension, revote/retrait,
refus de clôture non autorisée et métriques. Un hash instrumenté de120 bulletins
et12 options vérifie une limite déterministe de lectures, sans mesure fragile
du temps. Aucun nouveau fichier de test. Le cas utilise un seul processus natif pour
isoler son horloge figée du reste du runner.

Contre-épreuve : trois groupes échouent sur le baseline non corrigé (expiration,
limite/extension et lectures répétées), puis passent après correction.
Les104 contrôles ciblés de huit fichiers passent en trois secondes, notamment
les anciens contrats d'échéance, casse des salons et syntaxes de vote.
Les résultats de la full et des contrôles du paquet sont dans QUALIFICATION.md.

## Livraison

Application idempotente, contenus cumulés qualifiés et suppressions précédentes
conservés. Full suite visible --progress/ETA sans redirection, audits sécurité
et startup, inventaire et whitespace avant staging/restart/commit. Dev seul :
PID différent puis actif/stable dix secondes. commit.sh --skip-preflight reste
interactif et gère automatiquement la VERSION3.8dev. Aucun WorkingDirectory
imposé. Aucun service réel, SSH ou commit/push exécuté pendant la préparation.
Le contrôle de PID ne prouve pas la reconnexion IRC.
