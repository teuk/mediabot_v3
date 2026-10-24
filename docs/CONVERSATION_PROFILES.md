# Profils de conversation par salon

Les profils MB948 regroupent des réglages existants. Ils sont appliqués
uniquement sur demande explicite d'un Master ou Owner identifié, via chanset.
Ils ne changent ni le schéma, ni le cerveau Hailo, ni les clés de fournisseur.

```irc
!chanset #test profile show
!chanset #test profile quiet
!chanset #test profile balanced
!chanset #test profile animated
!chanset #test profile restore
```

Employer le préfixe réel de l'instance. `profile show` est obligatoire pour
consulter ; un argument manquant ou supplémentaire est refusé.

| Profil | HailoChatter | Spark | SparkAction | Ratio Hailo |
| --- | --- | --- | --- | --- |
| quiet | off | off | off | inchangé |
| balanced | off | on | on | inchangé |
| animated | on | on | on | base de 3 % |

Ces profils concernent les interventions spontanées. Hailo, HailoRespond,
HailoLearn, exclusions, arming global Spark, quotas et contrôles finaux de
livraison restent indépendants. Un profil n'allume pas un fournisseur, une
connexion ou un arming global manquant. Le taux Hailo de 3 % reste soumis au
frein adaptatif ; il ne promet pas un nombre de réponses par heure.

## Application et retour

Les trois portes et l'éventuel ratio sont changés dans une transaction, après
verrouillage et relecture du salon et du catalogue. Un catalogue incomplet,
une duplication de réglage ou une panne SQL refuse le lot. Une transaction
ouverte par un autre appel n'est jamais commitée ou annulée par le profil.
Les caches du salon sont invalidés seulement après un commit réussi.

`restore` retrouve les présences/absences des trois portes et la valeur ou
l'absence du ratio avant la dernière application effective. Les autres flags
et salons ne sont pas modifiés. Les identifiants techniques auto-incrémentés
des lignes de réglage peuvent changer ; ce sont les réglages qui sont restaurés.
Une répétition sans changement ne remplace pas le point de retour précédent.
Une nouvelle application effective remplace ce point par l'état immédiatement
précédent ; ce n'est pas un historique de plusieurs niveaux.

Le point de retour est volatil : il disparaît après redémarrage et refuse une
connexion DB différente. Il est limité à 128 salons, sans éviction silencieuse.
Les réglages eux-mêmes sont persistés en base et survivent au redémarrage.
Une édition des réglages concernés ou du catalogue entre application et retour
bloque toute restauration. `recovery_required` signifie qu'une panne a aussi
empêché le rollback DB : arrêter les nouvelles mutations et vérifier la base.
Ne pas réessayer aveuglément. Aucun profil n'est appliqué par l'installation.

## Scénarios à observer

| Situation | Choix initial | Vérification utile |
| --- | --- | --- |
| Salon calme, réponses à la demande | quiet | aucun Spark/HailoChatter spontané ; commandes explicites et HailoRespond conservent leurs portes |
| Une personne ou peu d'activité | balanced | Spark garde son adaptation à l'audience, ses silences et ses budgets |
| Conversation animée | animated | chance Hailo réduite, pauses Spark et revalidation tardive toujours actives |
| Commandes et sujet technique | quiet ou balanced | le préfixe réel continue d'exclure les commandes de l'apprentissage et des candidatures |

Les tests natifs MB942–MB945 couvrent fraîcheur, pression de sortie et révocation
pendant attente/frappe. Le test MB948 vérifie transactions, erreurs partielles,
retour, droits et isolation. Ils ne mesurent pas la qualité d'une conversation
réelle : noter pertinence, répétitions et chevauchements sur le développement
avant de choisir un profil sur #i/o en production.
