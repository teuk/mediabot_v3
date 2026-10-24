# MB945 — Hailo contrôle le départ réel et la livraison

## Problèmes reproduits

Une demande Hailo pouvait attendre derrière un autre salon, puis partir chez
le postéditeur après une désactivation ou un PART/rejoin. Le contrôle final
empêchait encore sa publication, mais ne supprimait pas ce calcul devenu inutile
et le prochain salon valide restait en attente derrière lui.

À l'autre extrémité du parcours, la façade Hailo utilisait un botPrivmsg
ordinaire. Sous antiflood, l'accusé de mise en file était pris pour un envoi :
compteur sent et contexte avançaient alors que rien n'avait été transmis.
Une levée ultérieure du flood pouvait publier cette réponse même après -Hailo.

## Correction

PostEditRuntime réutilise son contrôle d'autorisation/génération au moment où
la demande obtient son créneau réel. Un travail devenu invalide se termine
avec les codes existants, libère son créneau et laisse progresser la file.
Le diagnostic marque la postédition comme not_requested, sans inventer un
échec fournisseur pour une requête qui n'a pas été soumise.
Le contrôle après fournisseur et délai de frappe reste indépendant et intact.

La façade Hailo utilise l'option no_defer déjà disponible dans Helpers : une
réponse contextuelle est transmise maintenant ou refusée. Un refus de transport
ne devient ni une livraison réussie ni du contexte observé. Les appelants
ordinaires conservent la file générique ; aucune modification globale du flood.

Cette correction ne modifie aucun cerveau, apprentissage, quota, fréquence,
chanset, fournisseur, schéma ou service. Elle n'annule pas un calcul déjà parti.

## Qualification

Le test 1319 utilise les vraies fonctions Hailo, politiques de salon, queue,
PostEditRuntime, état IRC et façade Helpers. Horloge, fournisseur, transport et
lectures de flags sont capturés ; aucun compte, cerveau ou réseau réel.
Sur le snapshot MB944 intact : 34 échecs sur 54 assertions. Après correction :
54/54. Les cas couvrent HailoRespond, HailoChatter, le master, PART/rejoin,
progression intersalons, métriques, contexte, flood et révocation après frappe.

L'ancien test 1025 simulait sa génération comme périmée dès le départ tout en
attendant une requête fournisseur. Il simule désormais un vrai changement après
le départ et avant le timer ; son assertion de refus tardif reste en place.
Les résultats complets et limites locales sont dans QUALIFICATION.md.

## Livraison

Source : snap_mediabot_v3_teuk_20261024_132719.zip, SHA-256
cd3a93531eec5333baaedba982eb6e482c65372c541a7342cb27e03d74dcfdc5.
Le snapshot correspond aux huit payloads MB944 et à VERSION
3.6dev-20261024_112633, commit serveur 81755ac. MB944 est validé sur teuk :
30 819 assertions, sécurité GO/37 et intégrité de démarrage OK.
L'installateur garde ses hashes avant/après, sauvegarde et restauration si un
contrôle échoue. Suites ciblées, suite complète sans exclusion, sécurité et
intégrité restent obligatoires. Aucun redémarrage ou déploiement automatique.
