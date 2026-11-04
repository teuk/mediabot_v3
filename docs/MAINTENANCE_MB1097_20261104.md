# MB1097 — Durées SQL cohérentes dans !stats

Source : snap_mediabot_v3_teuk_20261104_130215.zip.
VERSION observée : 3.8dev-20261104_120204 ; MB1096 présent.

## Défaut et correction

!stats lisait des dates SQL puis reconstruisait leurs epochs avec timelocal.
Une date issue d’une session SQL UTC était donc relue dans le fuseau du
processus Perl, par exemple Canada/Eastern. Les durées « ago » pouvaient
être décalées de plusieurs heures, ou disparaître si la date ainsi convertie
semblait future. Les changements d’heure introduisaient encore un décalage.

Les trois lectures concernées fournissent désormais leur UNIX_TIMESTAMP dans
la même requête : maximum du dernier message, minimum de la première trace,
et dernier USER_SEEN. La fusion vif/archive conserve ensemble le libellé et
l’epoch de l’extremum choisi. Le SQL de filtrage, les bindings, les scopes,
le nombre de requêtes et les limites restent identiques ; seuls les champs
d’epoch sont ajoutés aux projections existantes.

Le calcul des durées utilise ces epochs et un seul time() pour l’affichage
de la ligne. Il ne dépend plus de timelocal ni du fuseau Perl. Les libellés
SQL, les unités historiques, compteurs, pourcentage, rang, karma, achievements,
cible IRC et audit sont conservés. L’affichage de last seen reste masqué
pour une demande sur soi-même. Une date future conserve son texte sans durée
négative ; une epoch absente ou malformée ne déclenche aucun repli local.
L’epoch zéro est admise, au lieu d’être traitée comme une valeur manquante.

## Vérifications

Les dix anciennes assertions du cas 691 (inspection du source et copie de
la logique achievements) sont remplacées par dix contrôles du vrai handler.
Un seul probe isolé contient l’horloge et les changements de TZ pour éviter
de modifier les autres tests. Il utilise une base SQLite privée avec un vif
et une archive, ainsi qu’une fonction UNIX_TIMESTAMP de fixture qui convertit
les dates selon un décalage de session SQL explicite.

Les 60 scénarios croisent cinq fuseaux du processus (UTC, Europe/Paris,
Canada/Eastern, Asia/Kolkata, Australia/Lord_Howe), trois décalages SQL fixes
(UTC, +05:30 et -05:00) et quatre dates, dont les deux bascules européennes
et une date estivale. La session SQL réelle de Mediabot reste en UTC ; le
test ne modifie aucun réglage de production.

Ils contrôlent les trois durées exactes, les libellés d’origine, les extrema
vif/archive, les comptes, pourcentages, rang, karma, achievements, cibles,
audit, absence de warnings et retour réussi. Neuf contrôles couvrent les
achievements absents/vides/en échec, la demande sur soi, l’historique vide,
les dates futures, l’epoch zéro et les métadonnées absentes/malformées.
Le scénario SQLite existant 1402 utilisé par la suite 1434 reçoit également
la fonction UNIX_TIMESTAMP pour continuer à exécuter les projections SQL
réelles avec ses contrôles de compteurs/rang. Aucune assertion n’est retirée
de cette suite. Aucun nouveau fichier de tests, dépendance, réseau ou sleep
ajouté ; le
nombre total d’assertions reste identique.

## Application

Le paquet vérifie les empreintes du snapshot et des changements précédents
qualifiés, applique ou reconnaît le patch, lance les ciblés puis la full
suite visible en --progress avec ETA, les audits et l’inventaire. Après
réussite, le script redémarre uniquement mediabot@dev.service, attend un
nouveau PID actif et le vérifie pendant dix secondes, puis appelle
commit.sh --skip-preflight interactif. VERSION reste automatique en 3.8dev.
Un échec bloque le commit ; un PID stable ne prouve pas la reconnexion IRC.

Si demandé par commit.sh, saisir KEEP DELETIONS pour les suppressions
précédemment qualifiées, puis confirmer le commit.

Un seul module applicatif change : Stats/Activity.pm. Aucun schéma, donnée,
configuration, README racine, commit.sh privé, radio ou YouTube modifié.
La préparation locale ne touche aucun service, commit ou push utilisateur.
