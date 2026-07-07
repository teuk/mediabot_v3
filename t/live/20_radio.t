# t/live/20_radio.t
# =============================================================================
#  Radio — matrice live A2 (direction 3.3, §A2)
#  Couvre : !song / !radiostatus / !radiomounts.
#  La radio lit un Icecast distant. En test, l'Icecast est presque toujours
#  ABSENT ou non configuré : le contrat attendu est alors un message d'erreur
#  ou "not configured" PROPRE, jamais un crash ni un silence. On valide donc
#  que chaque commande RÉPOND, quel que soit l'état du backend.
#  Certaines sous-commandes radio sont gardées (owner/master) ; on se logue.
# =============================================================================

return sub {
    my ($assert, $spy, $send_cmd, $send_private, $wait_reply,
        $botnick, $spynick, $channel, $cmdchar,
        $loginuser, $loginpass, $drain) = @_;

    my $r;

    $send_private->("login $loginuser $loginpass");
    $wait_reply->(qr/NOTICE \Q$spynick\E .*(?:successful|already)/i, 10);
    $drain->(2);

    # Contrat commun : réponse texte quelconque OU erreur radio propre.
    my $radio_reply = qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:Icecast|radio|listener|mount|now playing|song|not configured|error|unavailable|offline|disabled|No )/i;

    # -------------------------------------------------------------------------
    # 1. !song → titre courant OU erreur backend propre.
    # -------------------------------------------------------------------------
    $send_cmd->('song');
    $r = $wait_reply->($radio_reply, 15);
    $assert->ok(defined $r, "${cmdchar}song → réponse (titre ou erreur propre)");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 2. !radiostatus → statut Icecast OU erreur propre.
    # -------------------------------------------------------------------------
    $send_cmd->('radiostatus');
    $r = $wait_reply->($radio_reply, 15);
    $assert->ok(defined $r, "${cmdchar}radiostatus → statut ou erreur propre");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 3. !radiomounts → liste des mounts OU "No mounts"/erreur.
    # -------------------------------------------------------------------------
    $send_cmd->('radiomounts');
    $r = $wait_reply->($radio_reply, 15);
    $assert->ok(defined $r, "${cmdchar}radiomounts → liste ou erreur propre");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 4. Non-régression : après ces commandes réseau, le bot répond encore.
    # -------------------------------------------------------------------------
    $send_cmd->('version');
    $r = $wait_reply->(
        qr/PRIVMSG \Q$channel\E .*Mediabot version:/i, 10);
    $assert->ok(defined $r, 'le bot reste réactif après les commandes radio');
    $drain->(3);
};
