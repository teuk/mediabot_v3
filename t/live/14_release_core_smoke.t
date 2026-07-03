# t/live/14_release_core_smoke.t
# =============================================================================
# 3.3 release smoke: version, uptime, help, commands, status and status full.
# This case intentionally checks only stable response contracts. It does not
# depend on GitHub being reachable and it does not require exact build numbers.
# =============================================================================

return sub {
    my ($assert, $spy, $send_cmd, $send_private, $wait_reply,
        $botnick, $spynick, $channel, $cmdchar,
        $loginuser, $loginpass, $drain) = @_;

    my $r;

    $drain->(3);
    $send_cmd->('version');
    $r = $wait_reply->(
        qr/PRIVMSG \Q$channel\E .*Mediabot version:\s*\d+\.\d+(?:dev[-_]?[0-9_]+)?/i,
        5,
    );
    $assert->ok(defined $r, 'version replies immediately with a local release identity');
    $drain->(3);

    $send_cmd->('uptime');
    $r = $wait_reply->(
        qr/PRIVMSG \Q$channel\E .*\bup\b.*\bRAM\b.*\bload\b/i,
        10,
    );
    $assert->ok(defined $r, 'uptime reports process uptime, RAM and load');
    $drain->(3);

    $send_cmd->('help');
    $r = $wait_reply->(
        qr/NOTICE \Q$spynick\E .*(?:Available commands|Level\s+\d+\s*:|access\s+chaninfo\s+login)/i,
        10,
    );
    $assert->ok(defined $r, 'help answers by NOTICE without channel flood');
    $drain->(12);

    $send_cmd->('commands');
    $r = $wait_reply->(
        qr/NOTICE \Q$spynick\E .*Internal command categories:/i,
        10,
    );
    $assert->ok(defined $r, 'commands returns the categorized command index');
    $drain->(20);

    $send_private->("login $loginuser $loginpass");
    $wait_reply->(qr/NOTICE \Q$spynick\E .*(?:successful|already)/i, 10);
    $drain->(3);

    $send_private->('status');
    $r = $wait_reply->(
        qr/NOTICE \Q$spynick\E .*Mediabot v\d+\.\d+.*\bbot up\b/i,
        10,
    );
    $assert->ok(defined $r, 'status reports the same release identity and process uptime');
    $r = $wait_reply->(qr/NOTICE \Q$spynick\E .*Scheduler:/i, 10);
    $assert->ok(defined $r, 'status includes a bounded Scheduler summary');
    $drain->(8);

    $send_private->('status full');
    $r = $wait_reply->(qr/NOTICE \Q$spynick\E .*Scheduler tasks:/i, 10);
    $assert->ok(defined $r, 'status full exposes bounded Scheduler details');
};
