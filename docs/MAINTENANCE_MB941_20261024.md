# MB941 — Corriger la dépendance HTTP qui bloque le pilote mbweb

Date : 24 octobre 2026. Base serveur : MB940, commit poussé `7f025e7`,
VERSION `3.6dev-20261023_230142`. MB940 a passé 30 719 assertions Perl,
77 tests Node, les 37 invariants de sécurité et l'intégrité sur teuk.org.
Son source web est installé dans le dépôt, mais son déploiement a été arrêté
par npm audit avant la sauvegarde et avant tout arrêt ou remplacement du runtime.
La publication facultative et les droits des deux comptes du pilote restent à qualifier.

## Cause et correction

Le lockfile retenait body-parser 2.3.0, dépendance transitive d'Express.
L'audit local reproduit un résultat high : GHSA-27r3-jxmh-p828,
CVE-2026-111181, publié le 22 octobre 2026. L'avis du mainteneur indique
qu'une requête compressée suivie d'octets supplémentaires peut provoquer une
exception non interceptée et arrêter le processus. Les versions 2.x avant
2.4.0 sont affectées ; 2.4.0 est la version corrigée.

- Avis : https://github.com/expressjs/body-parser/security/advisories/GHSA-27r3-jxmh-p828
- Version : https://github.com/expressjs/body-parser/releases/tag/v2.4.0

Une mise à jour npm ciblée de body-parser régénère le lockfile :

| Dépendance verrouillée | Avant | Après |
| --- | --- | --- |
| body-parser | 2.3.0 | 2.4.0 |
| qs, minimum demandé par body-parser 2.4.0 | 6.16.0 | 6.16.1 |

Aucune autre entrée du graphe ne change. package.json, Express 5.2.1 et les
six dépendances directes restent identiques. Le seuil moderate du déployeur,
les contrôles d'authentification, les sessions et le déploiement transactionnel
restent en place. Le paquet ne modifie aucun schéma, fichier privé ou service.
Le message systemd concernant snmp_exporter est indépendant de cet audit npm.

## Qualification

Une installation npm ci propre utilise le lockfile corrigé et ignore les
scripts d'installation. npm audit --omit=dev --audit-level=moderate retourne
0 et ne signale aucune vulnérabilité à la date du contrôle. Les six dépendances
de production sont ensuite chargées depuis cette installation.

Le paquet contient un contrôle HTTP temporaire sur 127.0.0.1 et port attribué
par le système, avec les vrais parseurs Express et les mêmes limites que mbweb.
Dix vérifications couvrent JSON/formulaires Unicode, versions gzip, gzip/JSON
invalides, dépassement de 32 Kio brut ou décompressé, dépassement de 64 paramètres,
puis disponibilité après les rejets. Elles passent aussi sur la référence :
ce sont des contrôles de compatibilité, pas une reproduction du crash précis
ni une preuve indépendante de correction de l'avis. L'audit et la version
corrigée annoncée par le mainteneur motivent la mise à jour de sécurité.
Aucun service réel ni base applicative n'est sondé par ce contrôle.

Résultats locaux :

- Audit référence : une vulnérabilité high ; audit candidat : zéro signalement.
- Installation propre et chargement des dépendances : OK.
- Contrôle HTTP temporaire : 10/10.
- Tests Node : 77/77, aucun skip.
- Groupe Perl ciblé : 821/821 en 0 s.
- Suite Perl complète sans filtre : 30 701 succès et un échec sur 30 702,
  1 158 cas, 147 secondes. Le seul échec est le contrat d'updater MB786 déjà
  observé sur MB940 dans l'environnement hébergé ; aucune exclusion ou simulation
  d'identité systemd n'est ajoutée pour le masquer.
- Sécurité : GO, 37 invariants. Intégrité de démarrage : code 0, sortie vide.

La qualification livrée décrit en plus les neuf tests de l'installateur,
l'application/réapplication sur référence et la restauration des octets, modes
et de l'absence initiale du nouveau document. Aucun cas Perl ou Node du projet
n'est ajouté ; le contrôle HTTP et les outils d'installation restent dans le ZIP.

## Reprendre le pilote

L'installation du paquet applique trois chemins du dépôt. Elle qualifie les
dépendances dans un répertoire temporaire, puis exécute les 77 tests Node,
le groupe ciblé, la suite Perl complète, sécurité et intégrité. Toute erreur
restaure les fichiers écrits par cette tentative. Un accès au registre npm est
nécessaire ; une panne réseau ou un nouvel avis bloquant n'est jamais un succès.

Après tous les contrôles serveur verts, utiliser commit.sh pour VERSION,
commit et push, puis reprendre install/mbweb_deploy.sh deploy et verify avec
la même URL de santé locale. Le déployeur refait son propre audit avant de
toucher mbweb. Vérifier la route de diagnostic sans session (HTTP 401), puis
la publication choisie et les droits par salon. Ne pas synchroniser l'ancien
runtime vers le nouveau source. MB941 ne déploie pas /opt/mbweb/app et ne
redémarre pas le bot ; son statut actif ne prouve pas le chargement de MB940.
