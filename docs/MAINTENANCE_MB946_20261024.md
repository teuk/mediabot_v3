# MB946 — Retrouver une journée et poursuivre sa mémoire

## Bénéfice et périmètre

memory sélectionnait seulement une journée aléatoire, sans permettre de retrouver
la date affichée. MB946 ajoute YYYY-MM-DD à la même commande et un parcours
privé vers memory, onthisday et yearbook. Ce dernier réunit déjà activité,
citations et factoids de l'année ; ce lot constitue un premier lien de mémoire,
pas un moteur de recherche global.

La date est validée avant les lectures historiques : syntaxe stricte, mois,
jour et règles grégoriennes de bissextilité. Le moteur réutilise les mêmes
lectures de journée, avec une plage paramétrée et l'exclusion SQL des 30 jours.
La sélection ciblée n'exécute pas les recherches aléatoires de première,
dernière ou prochaine ligne. Sans argument, le comportement aléatoire demeure.

Les résultats restent en NOTICE au demandeur du salon courant, sous +OnThisDay.
Les renvois suivent le préfixe de l'instance, ne s'exécutent pas et respectent
les années prises en charge par yearbook. Les archives restent en scope content.
Une lecture en échec est signalée comme indisponible, au lieu d'être présentée
comme une journée sans données. Aucune donnée, fréquence ou politique d'archive
n'est créée ou modifiée, et aucune instance n'est redémarrée.

## Qualification

Le nouveau test 1320 utilise la commande, Context et le moteur mémoire natifs.
Seules les frontières de lecture et d'émission sont capturées. Ses 54 assertions
couvrent dates valides/invalides, année séculaire, plage et salon liés, archives,
NOTICE, navigation, préfixe personnalisé, exclusion récente, panne et absence
de résultat, refus d'un autre salon et maintien du parcours aléatoire.
Sur MB945 intact, 32 attentes du nouveau parcours échouent ; après MB946,
54/54 passent. Le test 846 conserve ses contrôles de routage privé/asynchrone
et documente désormais la nouvelle syntaxe dans l'aide.
Les résultats complets et limites locales sont dans QUALIFICATION.md.

## Référence et livraison

Snapshot fourni : snap_mediabot_v3_teuk_20261024_162811.zip, SHA-256
d404a70f142fbffd6a09e3aaa5bbcac14310c192559e8dba787f285ed1f73a51.
Les huit payloads MB945 concordent et VERSION vaut 3.6dev-20261024_142740.
Référence serveur : 7ddc6f7, MB945 validé avec 30 873 assertions, sécurité GO/37
et intégrité de démarrage OK.
Le paquet vérifie les hashes avant/après, conserve une sauvegarde et restaure
les fichiers de la tentative si un contrôle échoue. Les suites ciblées,
la suite complète sans exclusion, sécurité et intégrité restent exigées.
Aucun schéma, réglage privé ou service n'est modifié.
