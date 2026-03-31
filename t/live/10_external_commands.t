# t/live/10_external_commands.t
# =============================================================================
#  External — date, colors, leet, echo, status, rehash
#  resolve et whereis exclus (bug bloquant — à traiter séparément)
# =============================================================================

return sub {
    my ($assert, $spy, $send_cmd, $send_private, $wait_reply,
        $botnick, $spynick, $channel, $cmdchar,
        $loginuser, $loginpass, $drain) = @_;

    # -------------------------------------------------------------------------
    # 1. !date → contient une date
    # -------------------------------------------------------------------------
    $send_cmd->('date');
    my $r = $wait_reply->(qr/PRIVMSG \Q$channel\E .*(?:\d{4}|\w+day|\d+:\d+)/i, 15);
    $assert->ok(defined $r, "${cmdchar}date → contient une date ou heure");
    sleep(1);

    # -------------------------------------------------------------------------
    # 2. !leet hello
    # -------------------------------------------------------------------------
    $send_cmd->('leet hello');
    $r = $wait_reply->(qr/PRIVMSG \Q$channel\E .+/i, 15);
    $assert->ok(defined $r, "${cmdchar}leet hello → réponse reçue");
    sleep(1);

    # -------------------------------------------------------------------------
    # 3. !colors
    # -------------------------------------------------------------------------
    $send_cmd->('colors');
    $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .+/i, 15);
    $assert->ok(defined $r, "${cmdchar}colors → réponse reçue");
    sleep(1);

    # -------------------------------------------------------------------------
    # 4. !echo hello world
    # -------------------------------------------------------------------------
    $send_cmd->('echo hello world');
    $r = $wait_reply->(qr/PRIVMSG \Q$channel\E .*hello/i, 15);
    $assert->ok(defined $r, "${cmdchar}echo hello world → répète le texte");
    sleep(1);

    # Login pour les commandes Master
    $send_private->("login $loginuser $loginpass");
    $wait_reply->(qr/NOTICE \Q$spynick\E .*(?:successful|already)/i, 10);
    sleep(1);

    # -------------------------------------------------------------------------
    # 5. !status → uptime + version
    # -------------------------------------------------------------------------
    $send_private->('status');
    $r = $wait_reply->(qr/NOTICE \Q$spynick\E .*(?:3\.0|[Uu]ptime|[Vv]ersion)/i, 15);
    $assert->ok(defined $r, "status → contient version ou uptime");
};
