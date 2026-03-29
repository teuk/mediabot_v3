# t/live/06_commands_auth.t
# =============================================================================
#  Commandes authentifiées — vérifie le contenu des réponses.
# =============================================================================

return sub {
    my ($assert, $spy, $send_cmd, $send_private, $wait_reply,
        $botnick, $spynick, $channel, $cmdchar,
        $loginuser, $loginpass) = @_;

    # Setup login
    $send_private->("login $loginuser $loginpass");
    $wait_reply->(qr/NOTICE \Q$spynick\E .*successful/i, 15);
    sleep(1);

    # 1. !whoami → NOTICE contient "mboper"
    $send_cmd->('whoami');
    my $r = $wait_reply->(qr/NOTICE \Q$spynick\E .*mboper/i, 15);
    $assert->ok(defined $r, "${cmdchar}whoami → 'mboper' dans NOTICE");
    sleep(1);

    # 2. !users → contient un des users de test
    $send_cmd->('users');
    $r = $wait_reply->(qr/NOTICE \Q$spynick\E .*(?:mbtest|mboper|Owner|Master|\d)/i, 15);
    $assert->ok(defined $r, "${cmdchar}users → liste contient users de test");
    sleep(1);

    # 3. !chaninfo → contient le nom du canal
    my $chan_escaped = quotemeta($channel);
    $send_cmd->('chaninfo');
    $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*$chan_escaped/i, 15);
    $assert->ok(defined $r, "${cmdchar}chaninfo → nom du canal dans la réponse");
    sleep(1);

    # 4. !seen nick inconnu → contient "never" ou le nick
    $send_cmd->('seen zzzunknownnick999');
    $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:never|unknown|not|zzzunknownnick)/i, 15);
    $assert->ok(defined $r, "${cmdchar}seen nick inconnu → réponse cohérente");
};
