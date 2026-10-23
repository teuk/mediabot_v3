# MB936 — Contexte de livraison des VDM différées

Base : `snap_mediabot_v3_teuk_20261023_210333.zip`, VERSION
`3.6dev-20261023_190240`. Aucun changement du schéma de base de données.

## Défaut reproduit

La revue a poursuivi les lectures du registre de commandes, de la configuration,
des sources DTC/VDM, de Weather, des dépôts RSS et des chemins RandomQuote/Spark.
Le correctif retenu concerne la livraison asynchrone VDM. Les résultats tardifs
revérifiaient les réglages, la connexion et la présence du canal, mais pas leur
identité depuis le lancement de la requête.

Une déconnexion suivie d'une reconnexion sur le même objet IRC, un PART/JOIN,
un remplacement du transport ou de l'état runtime pouvaient ainsi recevoir une
ancienne réponse. Le même défaut touchait les requêtes manuelles et celles de
Spark. Les erreurs pouvaient aussi produire une notice devenue obsolète après
reconnexion. Le simple drapeau d'arrêt du bot n'était pas pris en compte ici.

## Correction

Les deux chemins utilisent maintenant `Mediabot::IRC::DeliveryContext`, déjà
partagé par les commandes asynchrones et d'autres sorties différées. Chaque
requête capture son transport IRC et, lorsqu'il est disponible, l'objet d'état
runtime et la génération JOIN du canal avant le lancement du fetcher.

À la réception du résultat, la réservation appartenant à cette requête est
libérée, puis le contexte est vérifié avant toute histoire ou notice d'erreur.
Un résultat obsolète est ignoré sans consommer l'historique anti-répétition et
sans empêcher une nouvelle requête. Un worker partagé continue à servir les
autres canaux et les nouveaux demandeurs dont le contexte reste valide.

Les contrôles existants +VDM/+Spark, présence, activité humaine et propriété
du callback restent en place. Syntaxe, ID demandé, format, couleurs, Unicode,
limites et fenêtre anti-répétition ne changent pas. Les appels isolés sans
transport ni état runtime conservent la compatibilité prévue par le helper.
Le helper commun et les callbacks de transport ne sont pas réimplémentés.

## Validation

Le cas `976_mb704_vdm_late_revalidation.t` remplace ses cinq vérifications à
fetcher simulé par huit groupes natifs et le contrôle du processus enfant.
Le catalogue reste à 1 158 cas, avec quatre assertions supplémentaires.
La fixture de dispatch numéroté expose explicitement son transport connecté,
au lieu de déclarer seulement les callbacks de politique autorisés.

La fixture exécute Runtime → AsyncFetcher → AsyncWorker → fork/pipe/watchers
dans une vraie boucle IO::Async. Les transitions viennent du véritable
ConversationRuntimeState. Le résultat du fournisseur et la sortie terminale
sont locaux : aucune requête HTTP, connexion IRC ou base du bot n'est utilisée.
Les PID sont ceux des vrais workers et leur terminaison/récolte est contrôlée.

Les scénarios couvrent les succès manuels/numérotés/façade/Spark, l'Unicode et
les badges, les reconnexions, PART/JOIN, remplacement du transport et de l'état,
changement de CASEMAPPING, arrêt, erreurs courantes et obsolètes, révocations
de réglages/activité, cleanup, coalescence entre canaux, reprise et anti-répétition.
La qualification du paquet détaille les mutations, suites entières et limites
locales sans annoncer une suite locale entièrement verte si elle ne l'est pas.

Le validator livré conserve syntaxes, groupe ciblé, suite complète sans filtre,
audit sécurité et intégrité de démarrage. L'installateur garde les empreintes,
sauvegardes, modes, absences et rollback des seuls fichiers de la tentative.
Aucun redémarrage, commit ou push n'est automatique.
