# t/live/02_routing.t
# =============================================================================
#  Routing — vérifie que chaque réponse arrive au bon endroit.
#  PRIVMSG canal vs NOTICE nick.
# =============================================================================

return sub {
    my ($assert, $spy, $send_cmd, $send_private, $wait_reply,
        $botnick, $spynick, $channel, $cmdchar,
        $loginuser, $loginpass) = @_;

    # 1. !date → PRIVMSG canal
    $send_cmd->('date');
    my $r = $wait_reply->(qr/PRIVMSG \Q$channel\E .+/i, 15);
    $assert->ok(defined $r, "${cmdchar}date → PRIVMSG canal (pas NOTICE)");
    sleep(1);

    # 2. !help → PRIVMSG canal
    $send_cmd->('help');
    $r = $wait_reply->(qr/PRIVMSG \Q$channel\E .+/i, 15);
    $assert->ok(defined $r, "${cmdchar}help → PRIVMSG canal (pas NOTICE)");
    sleep(1);

    # 3. !whoami sans auth → NOTICE au nick
    $send_cmd->('whoami');
    $r = $wait_reply->(qr/NOTICE \Q$spynick\E .+/i, 15);
    $assert->ok(defined $r, "${cmdchar}whoami sans auth → NOTICE nick (pas PRIVMSG canal)");
    sleep(1);

    # 4. !die sans auth → NOTICE au nick
    $send_cmd->('die');
    $r = $wait_reply->(qr/NOTICE \Q$spynick\E .+/i, 15);
    $assert->ok(defined $r, "${cmdchar}die sans auth → NOTICE nick (pas PRIVMSG canal)");
    sleep(1);

    # 5. login en privé → NOTICE au nick
    $send_private->('login nosuchuser wrongpass');
    $r = $wait_reply->(qr/NOTICE \Q$spynick\E .+/i, 15);
    $assert->ok(defined $r, "login en privé → NOTICE nick (pas PRIVMSG canal)");
};
