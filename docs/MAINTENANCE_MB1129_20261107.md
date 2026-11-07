# MB1129 — Confirmation IRC après mise à jour

Le marqueur de fin de `!update now` était supprimé dès le retour de
l’appel d’envoi. Le chemin public pouvait pourtant avoir refusé le
message ou l’avoir placé dans la file AntiFlood. Une déconnexion avant
l’écriture pouvait aussi faire perdre l’annonce privée.

Le marqueur reste en place tant que l’écriture IRC est en attente.
L’annonce publique passe toujours par les règles de sortie du salon,
sans être confiée à la file AntiFlood. Si l’envoi est refusé ou échoue,
un prochain login (notice privée) ou self-JOIN correspondant (message
public) peut réessayer. Un seul envoi par marqueur peut être en cours.

La confirmation porte sur l’écriture locale du transport, pas sur la
réception par un client IRC. Les envois ordinaires ne demandent pas de
Future et gardent leur fonctionnement. Le contrat de déploiement et le
format du marqueur restent les mêmes.

La régression utilise des refus simulés ainsi qu’une paire de sockets
locale avec le vrai transport IRC pour contrôler le moment de la
suppression du marqueur et le texte écrit.
