# MB1094 — Ne plus bloquer une file IRC sur une exception objet

## Source et périmètre

Snapshot snap_mediabot_v3_teuk_20261104_102655.zip.
VERSION 3.8dev-20261104_092518 ; MB1093 présent. Quatre chemins :
IRC/PacedOutput.pm, cas1311 existant, changelog et cette note.

## Panne reproduite

Une réponse longue est découpée en plusieurs PRIVMSG. La file absorbe les
échecs d’envoi et poursuit les lignes suivantes, car une tentative peut avoir
atteint IRC avant de lever son exception et ne doit pas être rejouée.

Mais le diagnostic utilisait `$@ || ...` puis une substitution directement
sur l’erreur. Un objet exception peut surcharger bool/string, voire lever
une nouvelle exception pendant ces conversions. Cette erreur secondaire
s’échappait du pump après retrait du message tenté, avant réarmement du timer.
La file restait active, sans notifier : les réponses ajoutées ensuite, même
courtes et sans délai demandé, restaient bloquées derrière elle. Le contexte
capturé par le lot pouvait également rester retenu.

Le pump examine maintenant seulement le type de l’erreur. Une référence
produit un diagnostic fixe, sans booléen ni conversion textuelle ; un scalaire
garde son texte normalisé, limité à512 caractères. La journalisation reste
best-effort. Les autres lignes et lots continuent, même si le logger échoue.

FIFO, délais, garde can_send, isolement des cibles et nombre de chunks acceptés
restent identiques. Le message tenté n’est pas rejoué. Le mode immédiat sans
boucle garde sa propagation de l’objet exception d’origine. NOTICE et
AntiFlood gardent leurs politiques distinctes, non modifiées par ce correctif.
Aucun schéma, donnée, configuration, code DB, VERSION, README racine, radio
ou YouTube modifié.

## Vérification

Quatre assertions groupées ajoutées au cas1311 natif existant :45 scénarios
sur une vraie boucle IO::Async et de vrais Countdown. Seuls les délais sont
ramenés à zéro par le point d’intégration déjà présent dans le test. Erreur
au premier, au milieu ou au dernier chunk ; erreur scalaire ou objet à
surcharge fausse/levante ; logger normal, absent ou levant lui-même.

Les contrôles portent sur les tentatives exactes, l’absence de doublon, la
suite du lot et de ses successeurs, une autre cible, les compteurs de retour,
le texte de journal borné, zéro surcharge invoquée et la libération des timers,
files et objets capturés. Trois vérifications du mode immédiat préservent
l’identité de l’exception sans créer de file. Aucun nouveau processus ou
fichier de test, aucun sleep ni dépendance ajouté. Résultats complets dans
QUALIFICATION.md.

Livraison : vérification des contenus cumulés, application idempotente,
syntaxe et ciblés, full --progress/ETA visible, audits, inventaire, staging
qualifié puis dev seul avec nouveau PID stable dix secondes et commit.sh
interactif. VERSION 3.8dev reste gérée par le script natif. Aucun contrôle
WorkingDirectory n’est imposé. Un PID stable ne prouve pas la reconnexion IRC.
