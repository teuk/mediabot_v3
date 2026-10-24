# MB948 — Finalisation regroupée de la roadmap

MB948 termine les parcours de développement restants dans un même lot : profils
par salon, création d'un plugin minimal avec atelier natif et adoption guidée.
Les directions déjà installées (diagnostic, garde-fous conversationnels, mémoire)
sont consolidées dans un bilan qui distingue livraison et validation terrain.

## Profils

`chanset #salon profile show|quiet|balanced|animated|restore` utilise le handler
existant. La porte Master/Owner demeure plus stricte que celle des réglages
ordinaires, car le profil peut changer le ratio Hailo. Quiet ferme trois portes
spontanées ; balanced laisse Spark seul ; animated ajoute HailoChatter à 3 %.
Les autres flags, fournisseurs, arming et contrôles de livraison sont inchangés.

Une transaction verrouille salon, catalogue et réglages concernés, relit avant
le commit et restaure sur un échec DBI, y compris un faux retour sans exception.
Les caches changent après succès seulement. Le retour à un niveau est volatil,
borné à 128 salons sans éviction, lié faiblement au handle DB pour éviter toute
confusion de connexion et protégé contre une édition concurrente. La présence
ou absence des réglages est restituée, sans garantie de même identifiant
technique auto-incrémenté. Aucun profil ne s'applique à l'installation.

## Contribution et adoption

Le générateur crée un paquet API v3 default-off, avec irc.reply seulement et
une configuration typée. Les fichiers sont créés exclusivement, sans écraser
une destination ou suivre un parent symlink. L'atelier temporaire utilise le
vrai PluginManager : désactivé, sans politique, observe/on/off, autre salon,
stop, unload et ancien callback. Il n'active rien dans un bot réel.
Le guide premier salon renvoie vers l'installation et la CI Debian existantes,
lie les outils natifs et fournit une démonstration privée sans import de logs.

## Qualification et référence

Le test 1322 exécute les transactions sur une SQLite privée en remplaçant
seulement FOR UPDATE, non pris en charge par SQLite. Cela vérifie les écritures
et retours atomiques ; cela ne qualifie pas les verrous concurrentiels MariaDB.
Il couvre les profils et leur retour, les pannes partielles/commit, la transaction
étrangère, la reconnexion, le catalogue, les droits, les caches et le générateur.
L'atelier charge le vrai paquet généré dans le véritable runtime natif.
Les résultats et limites sont consignés dans QUALIFICATION.md du paquet.

Base reconstruite du snapshot fourni snap_mediabot_v3_teuk_20261024_170406.zip
(SHA-256 27d2e2f94dd66421b141113a186e60c31247c20e863bd8d871a5d4a13a1d9e22),
puis des dix payloads MB947 dont les hashes ont été vérifiés. VERSION suit le
log de commit opérateur : 3.6dev-20261024_152222 / 73972f2.
L'opérateur confirme 31 006/31 006 assertions, GO/37 et démarrage OK pour MB947.
Le paquet vérifie les vrais hashes de chaque chemin, pas un SHA Git local fictif.

Aucun schéma, compte, réglage privé, ledger, service ou instance de production
n'est modifié par l'installation. Aucune recette de compte/Ansible retirée n'est
relancée. La clôture opérationnelle et une publication stable ne sont pas
revendiquées par cette livraison de source.
