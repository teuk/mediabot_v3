# MB926 — Acquérir un rappel encore en attente avant son envoi

Date : 2026-10-23. Base : snap_mediabot_v3_teuk_20261023_132654.zip.

## Défaut reproduit

deliverReminders sélectionne les rappels, puis les marque livrés avant envoi.
L'UPDATE ne filtrait que l'id et le code vérifiait execute, pas les lignes
affectées. La liste pouvait devenir périmée entre ces deux étapes :

- une annulation delivered=2 était écrasée par delivered=1, puis le rappel envoyé ;
- un rappel supprimé était encore envoyé depuis la copie en mémoire ;
- un rappel traité par un autre lecteur pouvait être envoyé une deuxième fois ;
- une récurrence annulée pouvait être recréée après cet envoi indésirable.

Deux connexions SQLite privées reproduisent ces situations avec les vrais
handlers et statements. Pour le rappel 21 annulé entre lecture et UPDATE,
la source l'envoie et remplace 2 par 1. Avec deux lecteurs, les trois rappels
sélectionnés produisent six sorties. Une annulation daily produit aussi
une nouvelle ligne de récurrence sur la source.

## Correction

L'UPDATE ajoute AND delivered=0. Seul le lecteur qui fait réellement passer
la ligne de 0 à 1 poursuit la livraison. Après execute réussi, rows doit être
défini et strictement positif ; le statement est terminé avant le passage
au candidat suivant si aucune ligne n'a été acquise.

Ce contrôle importe car DBI renvoie 0E0, valeur vraie, pour un execute réussi
à zéro ligne. Ce succès SQL n'autorise pas à envoyer une ancienne copie.
Le changement 0 vers 1 affecte bien la valeur : il ne dépend pas d'un UPDATE
réécrivant une valeur déjà identique. Aucune lecture préalable supplémentaire,
transaction ou verrou applicatif n'est ajouté.

Les requêtes de sélection, l'ordre, le scan de 20 lignes et la sélection de
trois candidats dus restent. Le marquage précède toujours l'appel de sortie.
Les formats UTF-8, le filtrage temporel, les échéances daily/weekly et les
alias publics sont conservés. Les autres commandes de CommunityState restent.
Le comportement historique après refus de sortie est conservé : le rappel
déjà marqué livré reste dans cet état. Le correctif porte sur l'acquisition SQL.

Aucun schéma/migration, configuration privée ou VERSION modifié.

## Contrôles

Le cas 397 conserve ses dix-sept critères et reçoit quatre assertions natives
regroupées. Un enfant Perl charge les vraies fonctions du module et l'alias
historique UserCommands, avec deux connexions DBI à un fichier SQLite privé.
Les mutations de l'autre connexion se placent entre lecture et UPDATE.
Pour le conflit de livraison, le second lecteur exécute aussi le vrai handler.
L'entrelacement est déterministe ; aucun résultat SQL n'est simulé.

Les contrôles couvrent 18 listes périmées : annulation, livraison ou suppression
sur chacun des trois rangs, via les deux entrées. Ils vérifient l'état final,
les sorties, la valeur native 0E0/rows=0, finish et les lignes étrangères.
Quatre annulations daily/weekly ne créent plus de récurrence. Deux scénarios
à deux lecteurs n'envoient chaque rappel sélectionné qu'une fois.

Vingt contrôles nominaux gardent les mêmes données, sorties et traces, après
normalisation du seul nouveau prédicat dans les chaînes SQL : un ou plusieurs
rappels, échéances futures, plafond du scan, daily/weekly, refus SQL réels,
sortie retournant faux et sortie levant une exception. Une observation depuis
l'autre connexion confirme le marquage avant chaque appel de sortie.
Horloge et timezone sont fixées seulement dans l'enfant ; aucune attente.

Le cas étendu donne 19/21 sur la source et 21/21 sur le candidat. Huit mutations
sont détectées par les nouvelles assertions ; les dix-sept anciens critères
passent dans chaque variante. Aucun nouveau cas ou fixture partagé :
le catalogue conserve 1 156 fichiers.

Les suites complètes et la limite locale MB786 figurent dans QUALIFICATION.md.
Le validateur livré impose la suite entière sans filtre.
