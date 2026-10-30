# Décision de release 3.7 — recette à terminer

**Préparation du 30 octobre 2026. Décision de publication non prise.**
La stable publiée reste 3.5 et VERSION reste sur 3.6dev. Le lot MB1022 prépare
les contrôles du futur commit stable ; il ne publie ni ne déploie la 3.7.

## Candidat à identifier après le commit de préparation

```text
Commit : à renseigner
VERSION : à renseigner
Date et instance de recette : à renseigner
Début/fin d'observation : à renseigner
Décision finale et limites connues : à renseigner
```

Une preuve locale fournie dans le paquet MB1022 porte sur son snapshot et ses
fixtures. Elle ne devient pas automatiquement une validation de ce prochain
commit sur teuk ou de sa CI distante.

## Critères de décision

| Contrôle | Résultat à obtenir | État du candidat à choisir |
| --- | --- | --- |
| Source et tests | Suite native complète avec --progress, Node mbweb, sécurité GO/37, intégrité et inventaire conformes ; aucun échec inexpliqué | À exécuter sur teuk |
| CI | CI normale et Debian 13 vertes sur le même commit ; installation fraîche MariaDB, migrations 3.3/3.5, restauration et réapplication réellement exécutées | À vérifier après push |
| Archives | RELEASE_REHEARSAL=OK, six fichiers identiques sur deux constructions ; lineage-only sur l'export exact, sans SQL local | À exécuter sur le commit choisi |
| Installation neuve réelle | Instance isolée, connexion/JOIN, premier Owner reconnu, help/features/diagnostic, mémoire privée ou absence explicite, retrait du plugin de démonstration | Toujours à réaliser ; ancien manque non effacé |
| Mise à jour et retour arrière | Updater natif sur une instance de recette isolée ; configuration, fichiers privés, posture des plugins et scores conservés ; restauration du code et des données vérifiée séparément | À consigner pour le candidat |
| Parcours sur dev | Partyline et reconnexion, chargement/retrait d'un plugin entre parties, jeu de mots et scores, rappel, profils conversationnels et previews déjà activés | À observer sur le candidat |
| mbweb réel | Compte autorisé accepté, compte sans droit refusé, anonyme refusé, publication absente/périmée clairement signalée sur le salon de recette | À exécuter avec des comptes existants |
| Observation | Période de fonctionnement normal, incluant redémarrage/reconnexion ; pas de crash inexpliqué, perte de données, réponses doublées ou dérive de ressources | Proposition : 72 h à dater et à confirmer |

Les anciens besoins de recette figurent dans
`RELEASE_ACCEPTANCE_3.6DEV.md`. Un succès ancien ou un simple état systemd
"active" ne prouve pas la nouvelle reconnexion ou une nouvelle recette web.
Les anciens probes Epiknet retirés ne doivent pas être relancés. Cette décision
ne demande pas de déployer les cinq productions ni de créer une orchestration
Ansible supplémentaire.

Pour les parcours IRC, utiliser le préfixe et les salons de dev déjà configurés,
avec les droits existants. Garder les essais de parties et de rappels sur le
salon de recette ; ne pas activer des fonctionnalités pour fabriquer une preuve.
Les profils conversationnels doivent être observés en situation : pertinence,
répétitions et chevauchements. Le silence d'un profil quiet peut être attendu.

## Point de départ opérateur

Depuis le dépôt, après les contrôles et le commit natif du modop :

```bash
git log -1 --format='%H %s'
cat VERSION
git status --short
bash tools/rehearse_release_artifacts.sh --version 3.7 --ref HEAD
```

La répétition ne modifie ni VERSION ni un service. Pour la lignée des migrations,
utiliser `tools/qualify_37_upgrade.sh --lineage-only` avec un export Git séparé
du même commit, comme montré dans le modop du paquet. Le test SQL reste réservé
au conteneur CI jetable ; aucune variable CI ne doit être simulée sur un serveur
installé pour contourner cette restriction.

## Décider puis seulement publier

Consigner les résultats attendus et observés, le commit, VERSION, l'instance,
le salon, la période et les limites connues. Ne conserver aucun secret ou
contenu privé dans ce relevé. Un contrôle non exécuté reste non exécuté.

Après décision explicite : préparer ensemble les identités publiques et les
notes finales, générer l'inventaire pour 3.7, qualifier ce commit final, puis
créer le tag et les archives correspondants avec `RELEASING.md`. La préparation
MB1022 laisse README et son en-tête, SECURITY, VERSION et schéma inchangés.
