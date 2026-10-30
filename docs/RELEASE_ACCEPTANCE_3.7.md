# Décision de release 3.7 — preuves et suivi opérateur

**Décision de sortie stable validée par l'opérateur le 30 octobre 2026.**
MB1023 finalise les métadonnées du commit 3.7. Le tag et les téléchargements
publics suivent les deux CI vertes sur ce commit final. Cette décision
conserve les limites terrain ci-dessous et n'autorise aucun déploiement
supplémentaire sur les instances de production.

## Preuves acquises sur la préparation MB1022

- Source : `1d2e97a4c7fa9e64476fe229429188f4c78a6921`, VERSION
  `3.6dev-20261030_084326` ; master distant vérifié sur cette identité.
- [CI complète](https://github.com/teuk/mediabot_v3/actions/runs/41028396306) :
  success, tentative 1 ; suite Perl, mbweb, sécurité, intégrité et inventaire.
- [CI Debian 13](https://github.com/teuk/mediabot_v3/actions/runs/41028396418) :
  success, tentative 1 ; configuration et MariaDB fraîches, unités statiques,
  migrations depuis 3.3 et 3.5, restauration et réapplication.
- Archives : retour opérateur `RELEASE_REHEARSAL=OK`, six fichiers identiques
  sur deux constructions ; `MB787_LINEAGE=OK`, cinq migrations ordonnées.
- Dev existant : recette précédente déclarée bonne par l'opérateur le
  30 octobre 2026, après redémarrage. Cela couvre les contrôles demandés de
  Partyline/Owner, reconnexion, découverte, conservation des scores, jeu et
  previews MixCloud. Les sorties détaillées n'ont pas été jointes ; il s'agit
  d'une confirmation opérateur, distincte d'un relevé automatique.

Ce retour ne vaut pas exécution des autres recettes ci-dessous. Les observations
de profils en usage, les comptes web, une nouvelle installation et un rollback
installé n'ont pas été rapportés. Leurs cases restent ouvertes.

## Commit final et publication à consigner

```text
Commit final 3.7 : à renseigner
VERSION finale : 3.7 (sortie approuvée ; publication après qualification)
Recette dev confirmée : 30 octobre 2026, teuk.org / #radiocapsule
Autres recettes : à renseigner
Début/fin d'observation : à renseigner
Décision finale : approuvée par l'opérateur le 30 octobre 2026
Limites connues : recettes terrain non rapportées ci-dessous, suivi opérateur
```

Une preuve locale fournie dans le paquet MB1022 porte sur son snapshot et ses
fixtures. Elle ne devient pas automatiquement une validation de ce prochain
commit sur teuk ou de sa CI distante.

## Preuves techniques et suivi opérateur

| Contrôle | Résultat à obtenir | État du candidat à choisir |
| --- | --- | --- |
| Source et tests | Suite native complète avec --progress, Node mbweb, sécurité GO/37, intégrité et inventaire conformes ; aucun échec inexpliqué | Préparation : CI verte ; commit final à qualifier |
| CI | CI normale et Debian 13 vertes sur le même commit ; installation fraîche MariaDB, migrations 3.3/3.5, restauration et réapplication réellement exécutées | Préparation : deux CI vertes ; à refaire sur le commit final |
| Archives | RELEASE_REHEARSAL=OK, six fichiers identiques sur deux constructions ; lineage-only sur l'export exact, sans SQL local | Préparation : validé ; à refaire sur le commit final |
| Installation neuve réelle | Instance isolée, connexion/JOIN, premier Owner reconnu, help/features/diagnostic, mémoire privée ou absence explicite, retrait du plugin de démonstration | Toujours à réaliser ; ancien manque non effacé |
| Mise à jour et retour arrière | Updater natif sur une instance de recette isolée ; configuration, fichiers privés, posture des plugins et scores conservés ; restauration du code et des données vérifiée séparément | À consigner pour le candidat |
| Parcours sur dev | Recette de redémarrage, Partyline, découverte, scores, jeu et previews déjà activés | Confirmation opérateur reçue ; retrait de plugin, rappel et observation des profils non rapportés |
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

## Qualification finale puis publication

La décision est acquise. Consigner les résultats attendus et observés, le commit, VERSION, l'instance,
le salon, la période et les limites connues. Ne conserver aucun secret ou
contenu privé dans ce relevé. Un contrôle non exécuté reste non exécuté.

Les identités publiques, les notes et l'inventaire sont synchronisés pour
3.7 dans MB1023. Qualifier ce commit final avec ses propres deux CI, puis
créer le tag et les archives correspondants avec `RELEASING.md`. Le lot final
synchronise uniquement les métadonnées ; l'en-tête README,
le code applicatif, la configuration et le schéma restent inchangés.
