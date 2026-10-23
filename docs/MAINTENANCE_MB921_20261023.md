# MB921 — Notes : refuser les index ambigus avant suppression

Date : 2026-10-23. Base : `snap_mediabot_v3_teuk_20261023_111437.zip`.

## Bug reproduit

Dans `mbNotes_ctx`, l'argument de `!notes del` était directement soustrait
de 1. La conversion numérique partielle de Perl et l'indexation entière
permettaient à `2oops`, `2.5` ou `2e0` de supprimer la deuxième note. Un
suffixe Unicode, un espace interne ou une fin de ligne pouvaient également
aboutir à cette suppression. Certaines formes produisaient un avertissement,
mais celui-ci n'empêchait ni le retrait du cache ni le DELETE persistant.

## Correction et compatibilité

La seule modification de production est une validation locale dans cette
branche. L'ordinal doit être un scalaire contenant un entier décimal ASCII
complet, éventuellement précédé de + et entouré d'espaces ou tabulations.
Les références, fractions, exposants, suffixes et caractères de contrôle
sont refusés. Les zéros initiaux sont retirés avant de borner le nombre de
chiffres significatifs par celui de la taille réelle de la liste. Aucune
conversion numérique n'a lieu pour une valeur démesurée ou non conforme.
Le contrôle de plage existant traite ensuite zéro et les positions absentes.

Les formes entières historiques restent : 1, 2, dernière position, 0002,
+2, +0002, espaces/tabulations et longue suite de zéros suivie de 2.
Un argument absent ou undef sélectionne toujours la première note, comme
auparavant. Un index refusé donne toujours `Note not found.` et retourne 1.
Le DELETE conserve le nick en minuscules et l'identifiant réel de la note.
Les numéros affichés par la recherche restent ceux de la liste complète.

Aucune modification de schéma, migration, requête/bind, configuration privée,
VERSION, sortie nominale, autre commande ou module partagé. La logique
historique de suppression en mémoire et de SQL best-effort reste en place :
ce correctif ne promet pas une nouvelle atomicité en cas de panne SQL.

## Protection contre les régressions

Le cas 673 existant conserve ses dix critères et reçoit quatre assertions
regroupées. Il appelle les vraies fonctions de CommunityState et l'alias
de compatibilité UserCommands, sur une base DBI/SQLite privée en AutoCommit.
Les requêtes originales s'exécutent sans traduction de dialecte ; un RootClass
de test enregistre SQL et binds puis délègue aux vrais statements SQLite.
Les sorties IRC sont interceptées. Aucun service public n'est contacté.

- 60 appels refusés : 15 valeurs, deux entrées, cache froid ou chaud. Vérification
  du retour, du message, de toutes les notes en cache et en base, de l'absence
  de DELETE et d'avertissement. Les valeurs couvrent aussi zéro, hors plage,
  entier de 1 024 chiffres, références et objet avec surcharge numérique.
- 44 appels valides : 11 scénarios, deux entrées, cache froid ou chaud. Traces
  source/candidat strictement identiques, y compris requêtes/binds, messages,
  retours et lignes persistantes. La liste sans suppression est incluse.
- Parcours natif recherche puis suppression : le résultat `[4] pizza recipe`
  supprime bien l'id persistant 77. Les autres ids non consécutifs 10/21/35/99
  et la note d'un autre utilisateur restent. Les textes accentués sont conservés.

Le cas étendu donne 13/14 sur la source et 14/14 après correction. Sept mutations
sur une copie indépendante sont détectées : ancienne coercition, ancre finale
absente, chiffres Unicode acceptés, référence surchargée acceptée, normalisation
des zéros absente, décalage d'un index, DELETE utilisant l'ordinal au lieu de l'id.
Les dix critères historiques passent dans chacun de ces mutants.

Aucun nouveau cas numéroté ou fixture partagé : les 1 156 fichiers restent.
Les suites complètes et les limites locales sont détaillées dans QUALIFICATION.md
du paquet. La validation par défaut conserve la suite entière sans filtre.
