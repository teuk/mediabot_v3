# MB1089 — Trois aperçus DDG avec leurs cibles

## Source et périmètre

Snapshot snap_mediabot_v3_teuk_20261103_180827.zip (MB1087), avec MB1088 optionnel.
Le paquet MB1089 r1 s'est arrêté avant application sur le contrôle HTTP 202.
La r2 accepte les états exacts MB1087, MB1088 et son propre état final.
Cinq chemins principaux : DDG, parent SearchCommand, cas 1439, changelog et
cette note. Depuis MB1087, la note historique MB1088 est également ajoutée.
Les 430 chemins cumulés précédents restent qualifiés ; total 431.

## Correction

Le diagnostic réel de teuk a obtenu 239680 caractères de DOM Chromium,
22 candidats, aucune vérification. Il montrait une publicité DDG y.js et le
même extrait publicitaire recopié sur Linux.org et Wikipédia. L'ancien code
remontait jusqu'au body quand le wrapper moderne n'avait pas la classe result.

Le parseur reconnaît maintenant result-title-a, les anciens result__a/result-link,
et les extraits data-result=snippet, result-snippet et result__snippet. Pour
chaque titre, il cherche le plus proche conteneur portant son propre extrait,
sans franchir un titre d'une autre cible ni body/html. Les doublons de titre
mobile/desktop vers la même cible sont permis puis dédupliqués. Une carte sans
extrait est ignorée, jamais complétée avec un texte voisin. Les marqueurs
publicitaires et les destinations DDG y.js/Bing aclick sont refusés avant tout
raccourcissement. Les redirections DDG uddg restent décodées une seule fois.

HTML HTTP reste la voie courte (8 s, 256 Kio). Si elle ne fournit pas trois
résultats, le helper Chromium déjà installé lit la page DDG normale : budget
virtuel 7 s, délai 15 s, DOM retenu <2 Mio, stderr 32 Kio, région et langue du
salon. Aucun autre moteur. Les vrais nœuds de vérification bloquent ; un mot
captcha dans un script ou un résultat ordinaire ne suffit pas à bloquer.

Quand trois résultats existent : exactement trois lignes, chacune avec rang,
titre en gras, extrait propre et cible entière bleu clair soulignée. Le lien
court privé remplace uniquement cette cible. Budget 400 octets UTF-8 styles
compris, titres <=80 octets et extrait ajusté à la place restante. Aucun libellé
Aperçu, aucune quatrième ligne de résumé. Si les deux accès web échouent, un
résumé Instant Answers valide reste un unique repli sans libellé, jamais une
liste fabriquée. Si moins de trois résultats existent, ils ne sont pas inventés.

Worker : 40 s, sortie 32 Kio, deux recherches simultanées. Lors d'un TERM pendant
Chromium, le fils marque l'annulation et laisse le helper achever sa fermeture
bornée ; aucun appel API/shortener ne suit. Grâce TERM 18 s et finalisation
forcée 19 s uniquement pour DDG ; Wikipedia conserve 0,2 s/1 s et deux lignes.
Le parent vérifie toujours les droits/chanset/contexte avant chaque réponse.

## Qualification et livraison

Huit assertions groupées dans le même cas 1439 : aucun nouveau fichier de test.
DOM moderne opaque, pub y.js en tête, doublons et extrait manquant, trois textes
propres, tailles/UTF-8, challenges, cibles refusées, chaîne HTTP202 -> Chromium,
annulation et absence de requête sur un lien publicitaire sont couverts.
Le vrai worker fork/pipe invoque le vrai helper natif et un exécutable navigateur
local de fixture. Trois gros résultats dépassent 16 Kio et restent sous 32 Kio.
La suite automatique reste hors ligne ; aucun Chromium réel n'est installé
ici. Le navigateur réel de teuk est contrôlé avant toute écriture du dépôt.

Le paquet inclut une copie exacte et checksummée du nouveau module pour ce
précontrôle : linux, faux objet conf vide, aucune lecture de secret/DB/IRC,
aucun raccourcissement. Un HTTP202 peut donc être suivi d'un Chromium réussi.
Trois titres/extraits/cibles distincts et les trois lignes rendues sont exigés.
Le même contrôle est répété avec le module installé après la full visible
--progress/ETA, les audits, l'inventaire et le contrôle whitespace.

Staging limité aux contenus cumulés qualifiés, suppressions précédentes
conservées. Dev seul avec PID différent puis stable dix secondes. commit.sh
privé inchangé, --skip-preflight interactif, VERSION 3.8dev automatique.
Aucun contrôle WorkingDirectory. Aucun service réel, SSH, commit/push ou
production exécuté pendant la préparation. Un PID stable ne prouve pas l'IRC.
README racine, sample conf, Wikipedia, radio, YouTube et VERSION inchangés.
Les résultats détaillés et limites locales sont dans QUALIFICATION.md du paquet.
