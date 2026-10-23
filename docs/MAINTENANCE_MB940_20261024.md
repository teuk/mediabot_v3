# MB940 — Échecs observés, plugins par salon et préparation mbweb

Base : MB939 validé sur le serveur et poussé dans 932e749,
VERSION 3.6dev-20261023_221453. La référence locale est reconstituée depuis le
dernier snapshot fourni et les payloads MB938/MB939 vérifiés ; elle ne prétend
pas être un nouveau snapshot ou un accès au serveur. Les préconditions SHA-256
du paquet vérifient chaque chemin avant écriture.

## Résultat

La suite de l'étape 2 complète `.diagnose` avec trois sources identifiées :
erreurs RSS encore retenues en base, exceptions des callbacks de scheduler,
politiques/échecs/quarantaines des instances API v3 chargées pour ce salon.
Le format structuré devient version 3 ; le texte privé est borné à 24 lignes.

La nouvelle observation de politique ne clone pas les configurations privées.
Les décisions utilisent l'explication native existante. Aucun registre, service
ou package n'est créé par la lecture. Le filtre du nom canonique, insensible à la casse mais sans fusion des alias
de ponctuation distincts en base, exclut les autres salons
et les agrégats d'instance. L'historique borné ne devient pas un historique complet.
Une ancienne génération de callback ne peut pas facturer son exception à un
successeur, et aucun message d'erreur n'est retenu dans les nouveaux compteurs.

Le source mbweb contient les vues HTML/JSON du diagnostic avec les droits par
salon existants, relus avant le fichier. La projection exclut les inventaires
globaux, tâches d'instance et données étrangères. Identité, UTF-8, taille et
fraîcheur sont vérifiés ; le HTML échappe chaque valeur. Une publication trop
ancienne est masquée. Une page n'appelle ni bot, shell ni fournisseur.

Une publication locale est proposée mais désactivée par défaut. Elle exige
répertoire sûr et allowlist explicite (huit salons maximum), traite un salon
par tick de cinq secondes et remplace atomiquement un fichier 0640 de 64 Kio
maximum. Elle refuse les symlinks/fichiers spéciaux et ne répare pas une
configuration manquante. Les erreurs sont contenues. `.diagnose` ne publie rien.

## Validation et limites

Le cas 07 existant garde treize groupes et ajoute six groupes natifs : vrais
plugins et politiques, historique/quarantaines/rétention/rechargement, requête
RSS et fautes DBI, propriété des exceptions du scheduler, publication facultative
et lecture Node du même JSON, puis bornes et confidentialité sur le fil.
Les fichiers Node existants ajoutent sept scénarios groupés d'accès, révocation,
identité, fraîcheur, fichiers natifs et échappement HTML. Aucun réseau distant
n'est appelé et aucune dépendance n'est ajoutée.

Le catalogue Perl reste à 1 158 cas. Six assertions supplémentaires sont dans
le cas 07 et six contrôles de structure existants suivent les deux modules
nouveaux. La qualification du paquet consigne les résultats complets, mutations,
répétitions d'installation et restaurations. La suite complète, les tests Node,
sécurité et intégrité restent obligatoires dans l'installateur livré.

Les compteurs ne couvrent pas les erreurs non enregistrées, les échecs de
configuration/rearm des timers ou les plugins v1/v2. Les erreurs RSS sont effacées
au prochain poll réussi ; les registres plugins disparaissent au retrait ou
redémarrage. Le timestamp RSS est en temps base, sans UTC inventé. Le rapport
ne prouve pas une livraison, une santé fournisseur ou la convergence code/source.

Pas de schéma modifié, de VERSION livrée, de fichier privé édité ou de publication
activée. Le sample documente seulement des défauts vides. Aucun répertoire
runtime, déploiement /opt/mbweb/app ou redémarrage réel n'est effectué. Le prochain
jalon est la qualification d'un pilote développement après installation et
chargement du code, avec accès accordé/refusé de deux comptes et cas périmé.
