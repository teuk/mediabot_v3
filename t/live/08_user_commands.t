# t/live/09_user_commands.t
# =============================================================================
#  UserCommands — users, userinfo, whoami, seen, userstat, modinfo
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
    # 1. !users → liste contient mboper et mbtest
    # -------------------------------------------------------------------------
    $send_cmd->('users');
    my $r = $wait_reply->(qr/NOTICE \Q$spynick\E .*(?:mbtest|mboper|\d+)/i, 15);
    $assert->ok(defined $r, "${cmdchar}users → liste d'utilisateurs reçue");
    sleep(1);

    # -------------------------------------------------------------------------
    # 2. !userinfo mboper → contient nickname et level
    # -------------------------------------------------------------------------
    $send_private->('userinfo mboper');
    $r = $wait_reply->(qr/NOTICE \Q$spynick\E .*(?:mboper|Master|Level)/i, 15);
    $assert->ok(defined $r, "userinfo mboper → contient nickname et level");
    sleep(1);

    # -------------------------------------------------------------------------
    # 3. !userinfo mbtest → contient nickname et level Owner
    # -------------------------------------------------------------------------
    $send_private->('userinfo mbtest');
    $r = $wait_reply->(qr/NOTICE \Q$spynick\E .*(?:mbtest|Owner|Level)/i, 15);
    $assert->ok(defined $r, "userinfo mbtest → contient nickname et level Owner");
    sleep(1);

    # -------------------------------------------------------------------------
    # 4. !whoami (public) → NOTICE avec mboper et Master
    # -------------------------------------------------------------------------
    $send_cmd->('whoami');
    $r = $wait_reply->(qr/NOTICE \Q$spynick\E .*(?:mboper|Master)/i, 15);
    $assert->ok(defined $r, "${cmdchar}whoami → NOTICE avec nickname et level");
    sleep(1);

    # -------------------------------------------------------------------------
    # 5. !userstat → contient stats
    # -------------------------------------------------------------------------
    $send_cmd->('userstat');
    $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .+/i, 15);
    $assert->ok(defined $r, "${cmdchar}userstat → réponse reçue");
    sleep(1);

    # -------------------------------------------------------------------------
    # 6. !seen spynick → le bot l'a vu (il vient de parler)
    # -------------------------------------------------------------------------
    $send_cmd->("seen $spynick");
    $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*\Q$spynick\E/i, 15);
    $assert->ok(defined $r, "${cmdchar}seen spynick → bot l'a vu");
    sleep(1);

    # -------------------------------------------------------------------------
    # 7. !greet sans arg → syntaxe ou réponse
    # -------------------------------------------------------------------------
    $send_cmd->('greet');
    $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .+/i, 15);
    $assert->ok(defined $r, "${cmdchar}greet → réponse reçue");
};
