# MB912 — Préserver les caractères de l'état des plugins au redémarrage

Date : 22 octobre 2026. Base : `snap_mediabot_v3_teuk_20261022_171027.zip`,
VERSION `3.6dev-20261022_151011`.

## Défaut confirmé

store_v3_runtime_state produisait une chaîne JSON de caractères, puis l'imprimait
sur un fichier brut. Au-dessus de Latin-1, Perl émettait un warning et écrivait
automatiquement de l'UTF-8. Le lecteur historique, non UTF-8, interprétait alors
chaque octet comme un caractère : préfixes Unicode et noms de canaux pouvaient
être altérés au prochain démarrage. Du Latin-1 seul pouvait rester fidèle pour
ce lecteur mais ne pas former du JSON UTF-8 valide. La vérification de longueur
avant écriture pouvait aussi compter moins de caractères que d'octets écrits.

## Correction ciblée

Une option ascii de JSON::PP encode les caractères non ASCII en échappements JSON,
y compris les paires de surrogates nécessaires aux caractères supplémentaires.
Le fichier reste du JSON standard et le lecteur existant restitue les caractères.
La limite inchangée de 1 MiB compte la longueur exacte de la représentation
écrite. Le fichier est refusé avant publication s'il la dépasse. Les échappements
peuvent prendre plus d'octets que l'UTF-8 brut ; la limite n'est pas augmentée.

Le schéma logique reste 1, avec les mêmes grants, politiques et bit enabled.
Les chemins, modes 0600, publication temporaire/rename, refus de symlink et
rollback mémoire des opérations persistantes sont conservés. Les documents
ASCII conservent leurs octets. Le lecteur historique reste inchangé, y compris
sa compatibilité Latin-1. Aucun fichier existant n'est migré et aucun texte
déjà altéré n'est réparé automatiquement.

## Validation

Huit assertions s'ajoutent au cas 1135 : cinq roundtrips ASCII, Latin-1,
BMP, caractère supplémentaire et accent combinant ; limite exacte ; refus
d'un document différent un octet au-delà ; relecture d'un fichier Latin-1
historique. Les vrais load/policy/enable persistants et restore à froid servent
aux roundtrips, avec contrôle des caractères, mode, enabled, JSON UTF-8
strict, octets ASCII nominaux, permissions 0600 et absence de warning.
Les anciennes douze assertions ne sont pas réécrites. Les nouveaux critères
passent 8/8 candidat et 3/8 référence. Trois mutations sont détectées.

Soixante-douze cycles nominaux comparent les six paquets fournis, grants vides ou
complets, enabled oui/non et modes off/observe/on. Pour Short Content, un préfixe
ASCII explicite et un endpoint fictif isolent la compatibilité nominale. Les
états restaurés, octets disque et permissions sont identiques entre référence
et candidat. Les vrais Scheduler/EventBus sont nettoyés ; aucun job de domaine,
HTTP, IRC réel ou SQL n'est déclenché pendant ces comparaisons.

Le groupe plugins/API v3 passe 2 719 assertions sur 133 fichiers ; les 37
invariants et l'intégrité de démarrage passent. QUALIFICATION.md détaille les
full suites locales, leurs limites et la qualification du paquet. Le validateur
livré conserve toute la suite obligatoire, sans exclusion.

Cinq chemins : quatre modifications et cette note nouvelle. Aucun nouveau
fixture ou cas numéroté ; les 1 156 cas restent. Aucun schéma de base/API,
stockage KV, paquet de plugin, configuration privée, VERSION, service, Partyline,
runner ou audit n'est modifié. Le paquet ne commit, ne push et ne restart pas.
