# t/live/03_auth.t
# =============================================================================
#  Authentification — vérifie les messages exacts.
# =============================================================================

return sub {
    my ($assert, $spy, $send_cmd, $send_private, $wait_reply,
        $botnick, $spynick, $channel, $cmdchar,
        $loginuser, $loginpass) = @_;

    # 1. User inconnu → "Unknown user"
    $send_private->('login nosuchuser_xyz wrongpass');
    my $r = $wait_reply->(qr/NOTICE \Q$spynick\E .*Unknown user/i, 15);
    $assert->ok(defined $r, "login user inconnu → 'Unknown user'");
    sleep(1);

    # 2. Mauvais password → "Bad password"
    $send_private->("login $loginuser wrongpass");
    $r = $wait_reply->(qr/NOTICE \Q$spynick\E .*Bad password/i, 15);
    $assert->ok(defined $r, "login mauvais password → 'Bad password'");
    sleep(1);

    # 3. Login correct → "successful" + nickname
    $send_private->("login $loginuser $loginpass");
    $r = $wait_reply->(qr/NOTICE \Q$spynick\E .*successful/i, 15);
    $assert->ok(defined $r, "login correct → 'successful'");
    sleep(1);

    # 4. whoami → contient "mboper"
    $send_private->('whoami');
    $r = $wait_reply->(qr/NOTICE \Q$spynick\E .*mboper/i, 15);
    $assert->ok(defined $r, "whoami après login → 'mboper'");
    sleep(1);

    # 5. whoami → contient "Master"
    $send_private->('whoami');
    $r = $wait_reply->(qr/NOTICE \Q$spynick\E .*Master/i, 15);
    $assert->ok(defined $r, "whoami après login → 'Master'");
};
