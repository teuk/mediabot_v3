# Procédure A3 — Déploiement instance Undernet + contrôle d'intégrité

Direction 3.3, Phase A, jalon **A3**. Objectif : déployer l'arbre COMPLET sur
l'instance Undernet et prouver, avant qu'elle se connecte, qu'aucune méthode ni
aucun handler ne manque et qu'aucun ancien module ne coexiste avec le nouveau
`mediabot.pl`.

## Pourquoi (rappel de l'incident)

Le 04/07/2026, l'instance Undernet a crashé plusieurs heures après le démarrage :
un déploiement partiel avait laissé un `mediabot.pl` appelant une méthode
(`hailo_record_activity`) absente des modules installés. `perl -c` ne détecte
pas ce désync (résolution de méthode = runtime). A3 comble ce trou.

## L'outil : `tools/startup_integrity_check.pl`

Vérifie quatre vecteurs, sans effet de bord (ne se connecte à rien, n'exécute
aucun handler) :

1. **Chargement** de tout l'arbre `Mediabot/*.pm` (pas juste `mediabot.pl`).
2. **Méthodes** appelées via `$mediabot->X` résolues par le package Mediabot
   (généralise le garde de démarrage mb449).
3. **Handlers de dispatch** (`*_ctx`, `\&refs`) réellement définis après
   chargement — teste `defined &{...}`, donc un slot d'export vide (module en
   retard) ne passe pas pour défini.
4. **Orphelins / manquants** via un manifest de référence : aucun `.pm`
   inattendu, aucun module attendu absent.

Code retour : `0` = OK, `1` = au moins un défaut (fail-closed).

### Matrice de détection validée

| Situation | Détecté |
|---|---|
| Arbre sain | OK (exit 0) |
| `mediabot.pl` appelle une méthode absente (bug Undernet) | FAIL (exit 1) |
| Handler `_ctx` manquant (module en retard) | FAIL (exit 1) |
| Module orphelin (ancien `.pm` resté) | FAIL (exit 1) |
| Module attendu manquant (déploiement partiel) | FAIL (exit 1) |

## Déploiement recommandé : `install/deploy_update.sh`

Ce script fait déjà les choses bien : clone COMPLET depuis GitHub (jamais de
copie fichier par fichier), restauration de `mediabot.conf` + brain Hailo,
rotation atomique par `mv` avec archive versionnée et rollback.

**A3 y ajoute** : après la validation `perl -c` de l'arbre stagé et AVANT la
bascule, il génère un manifest depuis le clone candidat (son propre arbre =
référence) et lance l'integrity check sur l'arbre stagé. Si le check échoue, il
refuse de basculer et l'ancienne release reste en place.

    # Sur l'hôte de l'instance Undernet (utilisateur du bot) :
    cd ~/mediabot_v3
    ./install/deploy_update.sh

Le script s'arrête tout seul si le clone est incohérent — rien n'est activé.

## Vérification manuelle (à tout moment)

Sur un arbre déjà en place, pour un contrôle indépendant :

    cd ~/mediabot_v3

    # 1. Générer le manifest de référence depuis l'archive CANDIDATE propre
    #    (à faire une fois, sur l'archive de release, PAS sur le working tree
    #    potentiellement pollué) :
    perl tools/startup_integrity_check.pl --gen-manifest /tmp/mediabot.manifest

    # 2. Vérifier l'arbre déployé contre cette référence :
    perl tools/startup_integrity_check.pl --manifest /tmp/mediabot.manifest
    echo "exit=$?"   # 0 attendu

Sans `--manifest`, les vecteurs [1][2][3] tournent quand même (seule la
détection d'orphelins [4] est désactivée) :

    perl tools/startup_integrity_check.pl

## Au démarrage

Le noyau du vecteur [2] est déjà exécuté à chaque start par `mediabot.pl`
(garde mb449/mb456, fail-closed). L'outil autonome étend la couverture et sert
surtout au moment du déploiement, avant la bascule.

## Checklist A3 (roadmap)

    [ ] déploiement de l'arbre complet (deploy_update.sh, clone entier)
    [ ] aucune copie fichier par fichier
    [ ] startup integrity check positif (exit 0) sur l'arbre stagé
    [ ] aucune méthode manquante ([2] vert)
    [ ] aucun handler de dispatch manquant ([3] vert)
    [ ] aucun ancien module mélangé au nouveau mediabot.pl ([4] vert)
    [ ] démarrage IRC réel, puis observation prolongée (le crash Undernet
        survenait des heures après le start : laisser tourner)
