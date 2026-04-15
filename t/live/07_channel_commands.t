# t/live/07_channel_commands.t
# =============================================================================
#  ChannelCommands — chaninfo, chanset list, badwords, access
#  Nécessite auth Master (mboper / testpass123)
# =============================================================================

return sub {
    my ($assert, $spy, $send_cmd, $send_private, $wait_reply,
        $botnick, $spynick, $channel, $cmdchar,
        $loginuser, $loginpass) = @_;

    # Setup : login Master
    $send_private->("login $loginuser $loginpass");
    $wait_reply->(qr/NOTICE \Q$spynick\E .*successful/i, 15);
    sleep(1);

    # -------------------------------------------------------------------------
    # 1. !chaninfo → contient le nom du canal
    # -------------------------------------------------------------------------
    my $chan_escaped = quotemeta($channel);
    $send_cmd->('chaninfo');
    my $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*$chan_escaped/i, 15);
    $assert->ok(defined $r, "${cmdchar}chaninfo → nom du canal dans la réponse");
    sleep(1);

    # -------------------------------------------------------------------------
    # 2. !chaninfo #inexistant → réponse d'erreur
    # -------------------------------------------------------------------------
    $send_cmd->('chaninfo #zzznotachan999');
    $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .+/i, 15);
    $assert->ok(defined $r, "${cmdchar}chaninfo canal inconnu → réponse reçue");
    sleep(1);

    # -------------------------------------------------------------------------
    # 3. !chanset → liste des chansets disponibles
    # -------------------------------------------------------------------------
    $send_cmd->('chanset');
    $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .+/i, 15);
    $assert->ok(defined $r, "${cmdchar}chanset sans arg → réponse reçue");
    sleep(1);

    # -------------------------------------------------------------------------
    # 4. !seen nick inconnu → réponse cohérente
    # -------------------------------------------------------------------------
    $send_cmd->('seen zzzunknownnick999');
    $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:never|unknown|not|zzz)/i, 15);
    $assert->ok(defined $r, "${cmdchar}seen nick inconnu → réponse cohérente");
    sleep(1);

    # -------------------------------------------------------------------------
    # 5. !access → liste accès sur le canal
    # -------------------------------------------------------------------------
    $send_cmd->('access');
    $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .+/i, 15);
    $assert->ok(defined $r, "${cmdchar}access → réponse reçue");
    sleep(1);

    # -------------------------------------------------------------------------
    # 6. chanlist en privé → canal de test dans la réponse
    # -------------------------------------------------------------------------
    $send_private->('chanlist');
    $r = $wait_reply->(qr/NOTICE \Q$spynick\E .*$chan_escaped/i, 15);
    $assert->ok(defined $r, "chanlist (privé) → canal de test dans la réponse");
};
