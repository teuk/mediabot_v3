# MB942 — Hailo : contexte récent et reprise de la roadmap

## Résultat attendu

Après une période calme, la correction d'une réponse Hailo ne reçoit plus les
phrases d'une ancienne discussion. Chaque phrase du contexte volatil expire
à cinq minutes. L'arrivée d'un nouveau message ne rafraîchit pas les autres.
Une attente dans la file ne permet pas de transmettre une phrase devenue
périmée ; le fournisseur reçoit le snapshot du déclencheur, filtré au départ.

La fenêtre reprend les cinq minutes déjà utilisées par ConversationRoom.
La limite de lignes, les exclusions commandes/bots, la génération de livraison,
le repli local et le délai de frappe restent actifs. Le cerveau appris n'est
ni effacé ni reconstruit. Aucun nouveau réglage privé n'est nécessaire.

## Preuve du défaut

Les scénarios du test 1316 exécutés sur MB941 échouent sur neuf des dix-sept
assertions : limite d'âge absente après silence, ancien sujet ravivé par un
message récent, dates futures après recul d'horloge et contexte périmé entre
la mise en file et le départ fournisseur. Ils passent avec le correctif.
Les horloges sont injectées ; aucun sommeil, appel IA ou message IRC réel.

## Clôture des essais d'exploitation précédents

MB938/939/940 et MB941 sont installés et poussés. Le runtime web MB941 est
déployé. Le pilote R3 publie #test, relu à deux dates successives, avec variable
initiale web confirmée. Le précontrôle R1 des droits anonymes et du lecteur est
passé sur teuk ; la recette réelle des droits de salon reste partielle.

Le 24 octobre à 09:21, R2 s'arrête en précontrôle sur
ACCOUNT_DELETE_CASCADES_REFUSED, avant la création d'un User. Le garde de cet
outil d'exploitation est trop général pour cette base ; ce refus ne démontre
pas un défaut de Mediabot ou du schéma. Le probe Ansible Epiknet s'arrête à la
validation du résultat, dont la cause précise est masquée par no_log. Il n'a
fait aucune activation ou écriture SQL en production. Aucun résultat de
qualification de production n'en est déduit.

Ne plus relancer les recettes de User/Ansible R1/R2. Aucun compte de recette
n'a été créé dans ces tentatives et aucun nettoyage SQL n'est demandé. Le
pilote R3 reste actif ; son backup pilot-2hr7ejdl est conservé. Toute future
commande Ansible partira du compte ansible. Le test fonctionnel à reprendre
ultérieurement vise #i/o sur Epiknet. Cette réserve ne bloque plus le code.

## Livraison

Paquet source MB942 sur la référence MB941/18f9fc5. L'installateur contrôle les
hashes avant toute écriture, sauvegarde les fichiers concernés et restaure
son application si un contrôle échoue. La suite ciblée, la suite complète,
les 37 invariants de sécurité et l'intégrité de démarrage restent obligatoires
sur teuk. Aucun redémarrage, déploiement mbweb ou changement de production
n'est déclenché. Le nouveau code sera chargé au prochain redémarrage normal
du bot après validation et commit. VERSION est géré par commit.sh.
