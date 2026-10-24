# MB949 — Un replay fidèle à la cadence configurée

## Défaut démontré

Le CLI du replay acceptait une configuration d'instance, mais le moteur ne
transmettait aucune des neuf options de cadence à Orchestrator. Il prenait
les exclusions et le préfixe réels, puis calculait les pauses avec les valeurs
par défaut. Une pause momentum configurée à 300 secondes pouvait ainsi produire
une candidature à 50 secondes ; une relance courte configurée restait bloquée
par le seuil de silence par défaut.

## Correction

Spark::Config centralise la correspondance des neuf clés déjà utilisées en
live. Le runtime et Replay réutilisent ce même mapping ; Orchestrator continue
de valider les valeurs et d'appliquer ses défauts, sans changement de fréquence
ou d'arming. Le replay accepte aussi l'événement metadata-only output/accepted
pour exercer la pression des sorties locales acceptées depuis MB943. Les
sorties refusées n'ajoutent pas de pression, et une sortie seule ne crée pas
d'audience. Aucun texte ou nick ne peut être attaché à cet événement.

## Qualification

Le test 1323 compare le replay au véritable _spark_runtime extrait du programme,
sans lancer son démarrage. Les neuf paramètres non standards sont vérifiés,
ainsi que les valeurs invalides/hors bornes, les décisions de silence et pause,
la sortie acceptée/refusée, les entrées interdites, l'audience dense et le vrai
préfixe. Les résultats et limites sont détaillés dans QUALIFICATION.md.
Aucun test ne revendique une observation réelle de #i/o ou une qualité de texte.
Le replay reste disarmé, sans fournisseur, envoi IRC ou lecture DB.

Référence : snapshot fourni snap_mediabot_v3_teuk_20261024_180501.zip,
SHA-256 b87ce7e150bd935ddd185686327b18926e10835af8869718ef3265e3b4d09ebe,
1 863 entrées et CRC vérifié. Les quinze payloads MB948 correspondent, VERSION
vaut 3.6dev-20261024_160402. Base serveur : 8ec1d43, 31 065 assertions,
sécurité GO/37 et intégrité de démarrage OK confirmées par l'opérateur.
Aucun nouveau réglage, schéma, service, compte ou profil n'est appliqué.
