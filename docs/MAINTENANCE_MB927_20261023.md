# MB927 — Préserver les bulletins des sondages après échéance

Date : 2026-10-23. Base : snap_mediabot_v3_teuk_20261023_134918.zip.

## Défaut reproduit

mbVote_ctx vérifiait la deadline et fermait paresseusement le sondage expiré.
mbUnvote_ctx vérifiait seulement active : tant qu'aucun nouveau vote n'avait
déclenché la clôture, un retrait pouvait modifier les résultats après échéance.

La sonde crée un vrai sondage de dix secondes et trois votes (deux pour thé,
un pour café). À t=1011, après une deadline de 1010, la source accepte le
retrait d'Alice et transforme la victoire en égalité. En mode pondéré,
le score du gagnant passe de 80 % à 67 %. Le résultat reste affiché actif.

## Correction et mutualisation limitée

Un helper privé _expire_poll_if_due porte le contrôle historique de mbVote_ctx :
poll présent et actif, time() strictement supérieur à deadline (défaut 0),
active passé à 0, même message d'expiration et arrêt de l'opération.
Vote et retrait l'utilisent désormais avant de modifier les bulletins.
Le helper est appelé comme fonction interne ; aucune méthode/export/API
publique supplémentaire et aucun nouveau module ne sont nécessaires.

Après échéance, un retrait ferme le sondage et conserve tous les votes.
Un résultat demandé ensuite reflète ces bulletins et scores conservés.
À la seconde exacte de l'échéance, les opérations restent permises selon
la règle historique strictement >, sans anticipation de clôture.

La prolongation explicite garde son comportement existant, notamment son
ancrage à maintenant si la deadline est passée mais le poll encore actif.
L'expiration reste paresseuse lors d'une tentative de vote/retrait ;
aucun timer n'est ajouté. Les consultations gardent leur fonctionnement.

Aucun SQL, schéma/migration, calcul de score, règle d'autorisation,
configuration privée ou VERSION modifié. Le reste de CommunityState,
y compris les rappels corrigés par MB926, reste identique.
Les compteurs et le comportement d'exception à la sortie restent ceux
de l'expiration historique de mbVote_ctx.

## Vérification native

Le cas 218 conserve exactement ses six critères et reçoit quatre assertions
regroupées. Un enfant Perl charge les vrais handlers et leurs alias
UserCommands, le vrai Context et un principal Master authentifié de fixture.
Création, votes, retrait, prolongation, arrêt et résultat exécutent le code
de production. L'horloge est fixée seulement dans l'enfant, sans attente.
Sorties et audit sont interceptés ; les compteurs sont enregistrés.
Aucun serveur IRC ni base n'est utilisé par ces scénarios en mémoire.

Seize retraits après échéance couvrent deux entrées, modes simple/pondéré,
acteur ayant ou non voté et deux instants expirés. Ils ne modifient que active,
conservent les bulletins et l'autre sondage de canal, émettent une seule
expiration et gardent les métriques. Le vrai résultat est fermé, avec le
gagnant et les pourcentages attendus.

Quarante scénarios nominaux ont des JSON complets strictement identiques
source/candidat, sans normalisation : retrait avant/à la deadline, absence
de vote, poll absent/fermé, retrait à la deadline après prolongation explicite,
vote avant/à la deadline, vote expiré et refus de sortie par exception.
Les deux entrées et les deux modes sont couverts, avec texte UTF-8,
état, retours, sorties, audits, métriques, erreurs et avertissements.

Le cas étendu donne 8/10 sur la source et 10/10 sur le candidat. Huit mutations
sont détectées par les nouvelles assertions ; les six anciens critères passent
dans chaque variante. Aucun cas ou fixture partagé supplémentaire :
le catalogue conserve 1 156 fichiers. Les suites et la limite locale MB786
sont détaillées dans QUALIFICATION.md du paquet.
