# MB893 — Module dédié à X/Twitter

## Périmètre

`Mediabot::External::XTwitter` regroupe les six fonctions X/Twitter :
normalisation des liens, extraction du titre et de la description, formatage
des compteurs, libellés de repli et gestionnaire FxTwitter/Chromium/cache/IRC.
`URL.pm` passe de 827 à 489 lignes. Ses huit corps de fonctions restants sont
identiques : extraction, décodage partagé, titres génériques, identité et
admission du cache, puis routage. Un commentaire obsolète sur Spotify est retiré.

Les six alias historiques restent disponibles dans URL. External importe les
quatre fonctions qu'il exposait déjà depuis le nouveau propriétaire. Les
17 exports optionnels de URL et les 33 exports par défaut de la façade ne
changent pas. Le module seul ne charge pas URL ni les fournisseurs IA ; les
fonctions dépendantes chargent URL à l'appel.

## Compatibilité

Les corps déplacés ne changent que par quatre `require` différés et la
qualification des appels vers les symboles historiques de URL. Cela garde les
surcharges des helpers X, des décodeurs HTML/JSON, de la clé de cache et du
navigateur. La fabrique HTTP et l'émetteur IRC gardent leurs points d'appel.
Time::HiRes est chargé explicitement sans importer `time` : la mesure du chemin
HTTP reste précise, et le cache conserve son horloge à la seconde entière.

Sont conservés :

- normalisation de x.com/twitter.com et refus des domaines ressemblants ;
- priorité de FxTwitter pour les URL de statut correspondantes ;
- GET de 6 secondes avec limite de 512 Kio et contrat JSON existant ;
- Chromium uniquement après échec du chemin rapide ou pour les autres liens ;
- options Chromium de 6 500 ms, alarme de 16 secondes et `fr-FR` ;
- journalisation et retour indéfini en cas d'exception du navigateur ;
- libellés de repli lorsque le DOM reste inutilisable sans exception ;
- priorités HTML, rejet des écrans génériques et retrait des guillemets décoratifs ;
- formatage actuel des compteurs, dont la frontière 999 999 vers 1M ;
- badge X blanc sur noir, crochets et RESET ;
- limites historiques de 200 caractères pour le texte du post (197 + `...`
  au-delà), puis 300 caractères pour le texte final ;
- cache de 600 secondes, identité sensible à la casse des ressources, relecture
  pour le demandeur/canal actuels et réparation des anciennes entrées sans message.

Ces règles ne sont pas converties en un traitement générique partagé avec
Facebook ou Instagram. Le transport IRC conserve ses protections existantes.
Aucun changement SQL, schéma, migration, configuration privée, VERSION, runner,
outil d'audit ou service. Aucun commit ni redémarrage par l'installateur.

## Vérification

Trois cas ajustent leurs lectures de source au propriétaire réel. Le cas X
cache existant ajoute cinq assertions : trois ordres de chargement avec égalité
des alias, une surcharge du décodeur titre/description et un parcours de hooks
normalisation/JSON/compteurs/cache avec livraison puis relecture. Le contrôle
de structure ajoute automatiquement trois assertions pour le module ; aucun
nouveau cas numéroté n'est ajouté.

Le groupe ciblé garde les validations de normalisation, replis, compteurs,
cache, routage et rendu des autres fournisseurs. La comparaison avant/après
utilise les vrais modules avec des réponses locales. Voir `QUALIFICATION.md`
dans le paquet pour les résultats et limites.

Le runtime local présente avant cette refactorisation l'échec MB786 connu du
répétiteur de mise à jour. L'installateur exige une suite complète verte sur le
serveur, suivie des audits sécurité et démarrage, sans exception MB786.
