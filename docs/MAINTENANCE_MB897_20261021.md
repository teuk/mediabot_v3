# MB897 — Admission des commandes dans un module IRC dédié

## Frontière

`Mediabot::IRC::CommandThrottle` devient propriétaire de quatre fonctions :
`_af_conf_int`, `checkCmdCooldown`, `checkChanFlood` et `checkNickFlood`.
Le module expose ces fonctions par nom qualifié ou import explicite ; aucun
export par défaut. Helpers conserve les quatre points d'entrée avec des
wrappers. Les appels des commandes et de Partyline ne sont pas réécrits.

Les compteurs restent dans le même objet bot. Le module ne déplace aucune
vérification dans un worker et ne crée ni timer, boucle ou processus.
La lecture partagée des paramètres résout le hook Helpers quand il existe,
sinon la fonction locale. Les notifications console et NOTICE résolvent aussi
les anciens helpers à l'appel ; ils peuvent être chargés si une vraie émission
est nécessaire. Des hooks déjà présents sont utilisés sans être écrasés.

Les calculs et les notifications interceptées fonctionnent sans charger
Helpers, HTTP ou DBI. Cela ne transforme pas la notification réelle en fonction
pure : elle conserve les dépendances des helpers émetteurs existants.

Helpers passe de 4 722 à 4 530 lignes ; le propriétaire compte 241 lignes.
Ses 96 autres corps de fonctions et ses exports par défaut sont identiques.
Le corps de checkAntiFlood, sa requête CHANNEL_FLOOD, les caches de paramètres,
la file de sortie différée et les émetteurs IRC restent en place. Le lecteur
_af_conf_int utilisé par la sortie atteint le même corps via son wrapper.

## Politiques conservées

- Cooldown : priorité de l'argument explicite, puis configuration de canal,
  puis défaut ; clé partagée des alias actualites/actualite/actu/news ; mêmes
  fenêtres pour ai, trivia, openai, awards et yearbook. État conservé dans le
  parent chez les appelants actuels.
- Canal : même fenêtre glissante, seuil strict, silence et mode warn-only,
  même cooldown de notification console, mêmes métriques. Le préfixe #
  historique n'est pas élargi aux autres formes de cible IRC.
- Pseudo : même lc, fenêtre, nettoyage TTL, strikes, mute de 300 secondes
  après trois strikes et cadence des NOTICE. Aucun remplacement par une
  autre règle de case mapping IRC.
- Clés et casse : les différences historiques entre recherche de configuration
  et clé d'état sont conservées. Les configurations Partyline retrouvent les
  mêmes champs dans l'objet bot.
- Temps : mêmes appels time à la seconde entière et mêmes bornes exactes ;
  aucune attente bloquante ni nouvelle horloge de production.
- Erreurs : mêmes effets d'état et propagation des exceptions des loggers,
  métriques ou notifications ; aucune nouvelle politique de récupération.

Aucun changement SQL, schéma, migration, configuration privée, VERSION,
service, runner ou outil d'audit. Aucun nouveau réglage n'est introduit.

## Vérification

Sept cas existants suivent le nouveau propriétaire de leurs inspections de
source. Le cas 336 ajoute six assertions, de 9 à 15 : trois processus Perl
frais avec horloge contrôlée pour les seuils, silences, expiration des mutes,
TTL et alias ; puis trois contrats de hooks et partage d'état entre les API.
Les notifications des probes sont interceptées, et un handle qui refuse tout
SQL protège le scénario de chargement autonome. Aucun nouveau cas numéroté.
Un mutant contournant le hook de configuration et retirant les NOTICE est
rejeté par cinq de ces assertions ; le candidat passe à 15/15.

Une comparaison externe exécute les vrais modules avant/après sur 107 scénarios,
via les wrappers puis directement : 42 configurations, 27 entrées/cooldowns,
14 parcours de canal, 18 parcours de pseudo et six parcours de sortie. Les
65 séquences d'événements représentent 619 appels ; l'état est copié après
chaque étape. Résultats, octets/flags, état, paramètres, logs, métriques,
notifications, erreurs et traces SQL sont identiques. Les horloges sont figées ;
seules les positions source et adresses de références sont normalisées.

Le groupe ciblé passe à 1 108 assertions sur 26 fichiers, avec sorties IRC,
files, workers et commandes consommatrices. Les suites complètes et les deux
limites du runtime local sont documentées dans QUALIFICATION.md. Aucun échec
n'est dispensé sur le serveur, y compris MB647 et MB786.

Base : snapshot `snap_mediabot_v3_teuk_20261021_225118.zip`, après MB896 validé
sur le serveur. Le catalogue reste de 1 156 fichiers de cas.
