# t/live/12_db_commands.t
# =============================================================================
#  DBCommands — addcmd, showcmd, countcmd, topcmd, searchcmd, delcmd
#  Nécessite auth Master (mboper / testpass123)
#  On crée une commande temporaire "zzztest_cmd_live" et on la nettoie.
# =============================================================================

return sub {
    my ($assert, $spy, $send_cmd, $send_private, $wait_reply,
        $botnick, $spynick, $channel, $cmdchar,
        $loginuser, $loginpass) = @_;

    my $test_cmd = 'zzztest_cmd_live';

    # Setup : login Master
    $send_private->("login $loginuser $loginpass");
    $wait_reply->(qr/NOTICE \Q$spynick\E .*successful/i, 15);
    sleep(1);

    # -------------------------------------------------------------------------
    # 1. !addcmd → créer une commande de test
    # -------------------------------------------------------------------------
    $send_cmd->("addcmd $test_cmd message general Test command live");
    my $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .+/i, 15);
    $assert->ok(defined $r, "${cmdchar}addcmd $test_cmd → commande créée");
    sleep(1);

    # -------------------------------------------------------------------------
    # 2. !m test_cmd → la commande répond
    # -------------------------------------------------------------------------
    $send_cmd->($test_cmd);
    sleep(1);  # laisser le temps à la DB de se stabiliser
    $r = $wait_reply->(qr/PRIVMSG \Q$channel\E .+/i, 20);
    $assert->ok(defined $r, "${cmdchar}$test_cmd → réponse de la commande créée");
    sleep(1);

    # -------------------------------------------------------------------------
    # 3. !showcmd test_cmd → contient la description
    # -------------------------------------------------------------------------
    $send_cmd->("showcmd $test_cmd");
    $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:$test_cmd|PRIVMSG)/i, 15);
    $assert->ok(defined $r, "${cmdchar}showcmd → détails de la commande");
    sleep(1);

    # -------------------------------------------------------------------------
    # 4. !countcmd → nombre de commandes
    # -------------------------------------------------------------------------
    $send_cmd->('countcmd');
    $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:\d+|[Nn]o (?:top )?command)/i, 15);
    $assert->ok(defined $r, "${cmdchar}countcmd → nombre de commandes");
    sleep(1);

    # -------------------------------------------------------------------------
    # 5. !topcmd → top commandes
    # -------------------------------------------------------------------------
    $send_cmd->('topcmd');
    $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .+/i, 15);
    $assert->ok(defined $r, "${cmdchar}topcmd → réponse reçue");
    sleep(1);

    # -------------------------------------------------------------------------
    # 6. !searchcmd test → trouve la commande de test
    # -------------------------------------------------------------------------
    $send_cmd->("searchcmd $test_cmd");
    $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .+/i, 15);
    $assert->ok(defined $r, "${cmdchar}searchcmd → trouve la commande de test");
    sleep(1);

    # -------------------------------------------------------------------------
    # 7. !delcmd test_cmd → suppression propre
    # -------------------------------------------------------------------------
    $send_cmd->("delcmd $test_cmd");
    $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .+/i, 15);
    $assert->ok(defined $r, "${cmdchar}delcmd $test_cmd → commande supprimée");
};
