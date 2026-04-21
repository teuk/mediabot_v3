# t/live/05_dispatch_private.t
# =============================================================================
#  Dispatch privé — Context unique (plus de dual path %ctx_commands).
# =============================================================================

return sub {
    my ($assert, $spy, $send_cmd, $send_private, $wait_reply,
        $botnick, $spynick, $channel, $cmdchar,
        $loginuser, $loginpass, $drain) = @_;

    # Garantir que le spy est délogué avant les tests "sans auth"
    # (au cas où une session précédente aurait laissé auth=1 en DB)
    $send_private->('logout');
    $drain->(5);
    sleep(1);

    # 1. whoami sans auth → refus
    $send_private->('whoami');
    my $r = $wait_reply->(qr/NOTICE \Q$spynick\E .*(?:logged|login|must)/i, 15);
    $assert->ok(defined $r, "whoami sans auth → refus");
    sleep(1);

    # 2. chanlist sans auth → refus (P11 corrigé)
    $send_private->('chanlist');
    $r = $wait_reply->(qr/NOTICE \Q$spynick\E .*(?:logged|login|must|level)/i, 15);
    $assert->ok(defined $r, "chanlist sans auth → refus (P11 corrigé)");
    sleep(1);

    # Setup login
    $send_private->("login $loginuser $loginpass");
    $wait_reply->(qr/NOTICE \Q$spynick\E .*successful/i, 15);
    sleep(1);

    # 3. whoami → "mboper"
    $send_private->('whoami');
    $r = $wait_reply->(qr/NOTICE \Q$spynick\E .*mboper/i, 15);
    $assert->ok(defined $r, "whoami après login → 'mboper'");
    sleep(1);

    # 4. whoami → "Master"
    $send_private->('whoami');
    $r = $wait_reply->(qr/NOTICE \Q$spynick\E .*Master/i, 15);
    $assert->ok(defined $r, "whoami après login → 'Master'");
    sleep(1);

    # 5. chanlist → canal de test dans la réponse
    my $chan_escaped = quotemeta($channel);
    $send_private->('chanlist');
    $r = $wait_reply->(qr/NOTICE \Q$spynick\E .*$chan_escaped/i, 15);
    $assert->ok(defined $r, "chanlist après login → canal dans la réponse");
    sleep(1);

    # 6. status → réponse reçue
    $send_private->('status');
    $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) \Q$spynick\E .+/i, 15);
    $assert->ok(defined $r, "status après login → réponse reçue");
    sleep(1);

    # 7. commande inconnue → pas de crash
    $send_private->('zzz_unknown_private_xyz');
    sleep(2);
    $send_cmd->('version');
    $r = $wait_reply->(qr/PRIVMSG \Q$channel\E .*(?:Mediabot|3\.)/i, 15);
    $assert->ok(defined $r, "commande privée inconnue → bot toujours vivant");
};
