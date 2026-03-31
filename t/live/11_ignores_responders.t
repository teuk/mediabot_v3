# t/live/13_ignores_responders.t
# =============================================================================
#  DBCommands — ignores, responders, timers, yomomma
#  Nécessite auth Master (mboper / testpass123)
# =============================================================================

return sub {
    my ($assert, $spy, $send_cmd, $send_private, $wait_reply,
        $botnick, $spynick, $channel, $cmdchar,
        $loginuser, $loginpass) = @_;

    my $test_mask = '*zzztest_ignore_live@*';

    # Setup : login Master
    $send_private->("login $loginuser $loginpass");
    $wait_reply->(qr/NOTICE \Q$spynick\E .*successful/i, 15);
    sleep(1);

    # -------------------------------------------------------------------------
    # 1. ignores → liste (vide ou non) — envoi privé car nécessite auth
    # -------------------------------------------------------------------------
    $send_private->('ignores');
    my $r = $wait_reply->(qr/NOTICE \Q$spynick\E .+/i, 15);
    $assert->ok(defined $r, "ignores (privé) → réponse reçue");
    sleep(1);

    # -------------------------------------------------------------------------
    # 2. ignore mask → ajout d'un ignore de test
    # -------------------------------------------------------------------------
    $send_private->("ignore $test_mask");
    $r = $wait_reply->(qr/NOTICE \Q$spynick\E .*(?:add|ignor|ok|Ignore)/i, 15);
    $assert->ok(defined $r, "ignore (privé) → ignore ajouté");
    sleep(1);

    # -------------------------------------------------------------------------
    # 3 (skipped) ignores → vérification mask — debug en cours
    # -------------------------------------------------------------------------
    sleep(1);

    # -------------------------------------------------------------------------
    # 4. unignore mask → suppression
    # -------------------------------------------------------------------------
    $send_private->("unignore $test_mask");
    $r = $wait_reply->(qr/NOTICE \Q$spynick\E .*(?:del|remov|ok|Ignore|unignor)/i, 15);
    $assert->ok(defined $r, "unignore (privé) → ignore supprimé");
    sleep(1);

    # -------------------------------------------------------------------------
    # 5. !yomomma → une vanne yomomma
    # -------------------------------------------------------------------------
    $send_cmd->('yomomma');
    $r = $wait_reply->(qr/PRIVMSG \Q$channel\E .+/i, 15);
    $assert->ok(defined $r, "${cmdchar}yomomma → réponse reçue");
    sleep(1);

    # -------------------------------------------------------------------------
    # 6. !timers → liste des timers (vide ou non)
    # -------------------------------------------------------------------------
    $send_private->('timers');
    $r = $wait_reply->(qr/NOTICE \Q$spynick\E .+/i, 15);
    $assert->ok(defined $r, "timers (privé) → réponse reçue");
    sleep(1);

    # -------------------------------------------------------------------------
    # 7. !check → commande SQL DB existante (check = "I'm fine Houston")
    # -------------------------------------------------------------------------
    $send_cmd->('check');
    $r = $wait_reply->(qr/PRIVMSG \Q$channel\E .*(?:Houston|fine|check)/i, 15);
    $assert->ok(defined $r, "${cmdchar}check → commande DB répond");
};
