# t/live/16_karma.t
# =============================================================================
#  Karma — matrice live A2 (direction 3.3, §A2)
#  Couvre : vote !karma +/- <nick>, lecture !karma <nick>, !karmatop,
#           !karmadiff, !karmainfo, garde-fou anti-auto-vote.
#  Le vote se fait sur un nick PRÉSENT sur le canal : le spy (`$spynick`) est
#  justement présent, on vote donc pour lui depuis le bot-testeur… mais c'est le
#  SPY qui envoie les commandes, donc voter pour le spy = auto-vote (refusé).
#  On vote donc pour le BOT ($botnick), qui est présent, et on lit son score.
#  Aucune auth requise : karma est public.
# =============================================================================

return sub {
    my ($assert, $spy, $send_cmd, $send_private, $wait_reply,
        $botnick, $spynick, $channel, $cmdchar,
        $loginuser, $loginpass, $drain) = @_;

    my $r;
    $drain->(3);

    # -------------------------------------------------------------------------
    # 1. Garde-fou : on ne peut pas voter pour soi-même.
    #    Le spy vote pour lui-même -> refus explicite.
    # -------------------------------------------------------------------------
    $send_cmd->("karma + $spynick");
    $r = $wait_reply->(
        qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:can't change your own|own karma)/i,
        10,
    );
    $assert->ok(defined $r, "${cmdchar}karma + self → auto-vote refusé");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 2. Vote positif pour le bot (présent sur le canal).
    # -------------------------------------------------------------------------
    $send_cmd->("karma + $botnick");
    $r = $wait_reply->(
        qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:\Q$botnick\E|karma|[+-]?\d+)/i,
        10,
    );
    $assert->ok(defined $r, "${cmdchar}karma + $botnick → vote enregistré");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 3. Lecture du score courant du bot sur ce canal.
    # -------------------------------------------------------------------------
    $send_cmd->("karma $botnick");
    $r = $wait_reply->(
        qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:\Q$botnick\E.*[+-]?\d+|karma)/i,
        10,
    );
    $assert->ok(defined $r, "${cmdchar}karma $botnick → affiche un score");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 4. !karmatop → classement (au moins une ligne, ou 'no karma').
    # -------------------------------------------------------------------------
    $send_cmd->('karmatop');
    $r = $wait_reply->(
        qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:\d+|no karma|empty)/i,
        10,
    );
    $assert->ok(defined $r, "${cmdchar}karmatop → classement ou vide");
    $drain->(5);

    # -------------------------------------------------------------------------
    # 5. !karmadiff <bot> → delta 24h (canal courant, mb464).
    # -------------------------------------------------------------------------
    $send_cmd->("karmadiff $botnick");
    $r = $wait_reply->(
        qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .+/i,
        10,
    );
    $assert->ok(defined $r, "${cmdchar}karmadiff $botnick → réponse reçue");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 6. !karmainfo <bot> → stats détaillées.
    # -------------------------------------------------------------------------
    $send_cmd->("karmainfo $botnick");
    $r = $wait_reply->(
        qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .+/i,
        10,
    );
    $assert->ok(defined $r, "${cmdchar}karmainfo $botnick → réponse reçue");
    $drain->(3);
};
