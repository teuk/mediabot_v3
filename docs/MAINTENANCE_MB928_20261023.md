# MB928 — Sécuriser la transaction de deluser

Date : 2026-10-23. Base : snap_mediabot_v3_teuk_20261023_142239.zip.

## Défaut reproduit

La commande deluser utilise déjà une transaction pour supprimer successivement
USER_CHANNEL, USER_HOSTMASK, USER_SEEN et USER. Mais elle ne vérifiait aucun
retour de begin_work, des quatre DELETE ou de commit. Avec RaiseError => 0,
réglage du connecteur de production, un simple eval ne détecte pas ces erreurs.
Le schéma fourni utilise InnoDB pour ces quatre tables ; aucune modification
de leur structure ou de leur moteur n'est nécessaire.

Une sonde DBI/SQLite réelle refuse chaque DELETE par un trigger RAISE(ABORT).
Sur la source, en mode sans exception, la commande continue, valide les autres
suppressions et annonce que l'utilisateur a été supprimé. Si le dernier DELETE
échoue, le compte reste présent mais ses liens ont déjà été effacés.
Un refus réel de commit par contrainte différée est aussi annoncé comme succès.

Si une transaction existe avant l'appel, begin_work échoue. La source peut
néanmoins exécuter et valider la suppression avec RaiseError désactivé ;
avec RaiseError activé, son rollback inconditionnel annule le travail antérieur
de l'appelant. Ce travail est distinct de la commande de suppression.

Enfin, le bloc de rollback écrasait $@ avant son affichage dans le journal :
le détail de l'erreur disparaissait même lorsqu'une exception avait été levée.

## Correction circonscrite

Chaque étape DBI doit réussir : begin_work, chaque DELETE, puis commit.
Une erreur de retour déclenche la branche d'échec existante et arrête la
séquence immédiatement. Un marqueur local n'autorise le rollback que si
cette commande a elle-même réussi begin_work. Aucune transaction imbriquée,
nouveau savepoint ou nouvelle API n'est introduit.

L'erreur initiale est capturée avant la tentative de rollback pour le journal
interne. La réponse à l'opérateur reste générique. Le message de succès et
l'audit de suppression ne sont atteints qu'après un commit confirmé.

Les textes SQL, paramètres, ordre des suppressions, confirmation en deux étapes,
frontière de 30 secondes incluse et permissions restent identiques.
Le succès DBI 0E0 (zéro ligne affectée) reste accepté, notamment pour un compte
sans liens associés. Le correctif ne recherche pas un nombre minimal de lignes.

La confirmation est consommée avant une tentative, comme auparavant : après
un échec, une nouvelle opération demande de nouveau les deux étapes.
Le périmètre de cascade reste celui de la commande existante.
Aucun autre handler, SQL de production, schéma/migration, configuration privée
ou VERSION n'est modifié.

## Qualification native

Le cas 163 conserve ses huit critères et ajoute quatre assertions regroupées,
sans nouveau fichier du catalogue ni fixture partagé. Un enfant Perl exécute
les vrais handlers UserCommands et leur alias importé dans Mediabot, le vrai
Context et un vrai User authentifié Master ; les permissions ne sont pas
remplacées. L'horloge est fixée seulement dans cet enfant, sans attente.

72 scénarios couvrent deux points d'entrée et RaiseError 0/1 :

- 16 refus réels de DELETE et quatre refus réels de commit ;
- quatre refus de begin_work sur une transaction déjà ouverte contenant
  une écriture en attente appartenant à l'appelant ;
- 48 cas nominaux : suppression ordinaire, liens associés absents,
  nick appelant injecté, première demande seule, confirmation à 30/31 secondes,
  autre opérateur, argument absent, compte inconnu, niveau insuffisant,
  utilisateur non authentifié et nom ASCII/UTF-8.

Deux connexions SQLite par scénario contrôlent à la fois l'état de l'appelant
et les données visibles depuis un autre lecteur. Les tables et contraintes
sont privées à la fixture. Les requêtes ne sont ni réécrites ni remplacées ;
la sous-classe DBI trace les appels puis les délègue aux méthodes natives.
Sortie IRC et audit sont enregistrés, sans serveur IRC ni base réelle.

Les 24 échecs préservent les données initiales ; le travail antérieur reste
non validé et accessible à son propriétaire lors d'un refus de begin_work.
Les traces imposent l'arrêt au premier échec et l'absence de faux audit.
Les JSON complets des 48 cas nominaux sont strictement identiques à ceux de
la source, sans normalisation. Les suppressions sans liens vérifient 0E0.

SQLite/DBI peut émettre un avertissement de rollback après son refus de commit
sur contrainte différée ; le scénario capture cet avertissement et vérifie
la restauration effective sur les deux connexions. Il ne s'agit pas d'un test
MariaDB en production ni d'une garantie en cas de perte réseau au commit.

Cas étendu : source 10/12, candidat 12/12. Huit mutations sont détectées par
les nouveaux critères, les huit anciens passant dans toutes les variantes.
Les suites complètes et l'installation sont détaillées dans QUALIFICATION.md.
En plus de MB786, le contrôle Doctor MB647 peut échouer ici car les PID du
processus et ceux de /proc appartiennent à deux namespaces différents.
Ce même échec est reproduit sur la source inchangée ; Doctor et son test
ne sont pas modifiés, et aucune exemption n'est livrée.
