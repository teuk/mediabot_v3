# t/live/17_trivia.t
# =============================================================================
#  Trivia — matrice live A2 (direction 3.3, §A2)
#  Couvre : lancement !trivia, catégories, score, top, arrêt propre.
#  Trivia interroge l'Open Trivia DB (réseau). En environnement sans accès
#  sortant, le lancement doit échouer PROPREMENT (message d'erreur, pas de
#  crash). On valide donc le CONTRAT de réponse, pas le contenu de la question.
#  On arrête toujours la manche à la fin (!triviastop) pour ne pas laisser
#  d'état actif derrière soi.
#  Public : aucune auth requise pour jouer ; reset/stop peuvent l'exiger.
# =============================================================================

return sub {
    my ($assert, $spy, $send_cmd, $send_private, $wait_reply,
        $botnick, $spynick, $channel, $cmdchar,
        $loginuser, $loginpass, $drain) = @_;

    my $r;
    $drain->(3);

    # -------------------------------------------------------------------------
    # 1. !trivia categories → liste de catégories (locale, pas de réseau).
    # -------------------------------------------------------------------------
    $send_cmd->('trivia categories');
    $r = $wait_reply->(
        qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*Trivia categories:/i,
        10,
    );
    $assert->ok(defined $r, "${cmdchar}trivia categories → liste de catégories");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 2. !trivia → lancement : soit une question, soit une erreur réseau propre.
    #    Dans les deux cas le bot RÉPOND (pas de silence, pas de crash).
    # -------------------------------------------------------------------------
    $send_cmd->('trivia');
    $r = $wait_reply->(
        qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:trivia|question|category|\?|error|unavailable|could not|try again|already)/i,
        15,
    );
    $assert->ok(defined $r, "${cmdchar}trivia → question OU erreur réseau propre (pas de crash)");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 3. !triviascore → score courant du joueur (0 si rien).
    # -------------------------------------------------------------------------
    $send_cmd->('triviascore');
    $r = $wait_reply->(
        qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:score|\d+|no)/i,
        10,
    );
    $assert->ok(defined $r, "${cmdchar}triviascore → réponse reçue");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 4. !triviatop → classement (ou vide).
    # -------------------------------------------------------------------------
    $send_cmd->('triviatop');
    $r = $wait_reply->(
        qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:\d+|no|empty|top)/i,
        10,
    );
    $assert->ok(defined $r, "${cmdchar}triviatop → classement ou vide");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 5. !triviastop → arrêt de la manche active (nettoyage d'état).
    #    Peut nécessiter un login selon le niveau ; on tente d'abord public,
    #    puis on s'authentifie et on réessaie si besoin.
    # -------------------------------------------------------------------------
    $send_cmd->('triviastop');
    $r = $wait_reply->(
        qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:stop|no active|no trivia|ended|not running|level|permission)/i,
        10,
    );
    unless (defined $r) {
        # Fallback authentifié (au cas où triviastop est gardé).
        $send_private->("login $loginuser $loginpass");
        $wait_reply->(qr/NOTICE \Q$spynick\E .*(?:successful|already)/i, 10);
        $drain->(2);
        $send_cmd->('triviastop');
        $r = $wait_reply->(
            qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:stop|no active|no trivia|ended|not running)/i,
            10,
        );
    }
    $assert->ok(defined $r, "${cmdchar}triviastop → manche arrêtée ou déjà inactive");
    $drain->(3);
};
