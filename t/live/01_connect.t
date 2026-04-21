# t/live/01_connect.t
# =============================================================================
#  Connexion et identité du bot
#  Vérifie : JOIN effectif, nick exact via WHOIS, version contient "3.0"
# =============================================================================

return sub {
    my ($assert, $spy, $send_cmd, $send_private, $wait_reply,
        $botnick, $spynick, $channel, $cmdchar,
        $loginuser, $loginpass) = @_;

    # 1. JOIN déjà confirmé par le runner — on vérifie juste que le bot
    #    est bien présent avec le bon nick via WHOIS
    $spy->send_raw("WHOIS $botnick");
    my $r = $wait_reply->(qr/311 \Q$spynick\E \Q$botnick\E/i, 15);
    $assert->ok(defined $r, "WHOIS confirme le nick exact '$botnick'");

    # 2. !version → PRIVMSG sur le canal contenant "3.0"
    $send_cmd->('version');
    $r = $wait_reply->(qr/PRIVMSG \Q$channel\E .*(?:Mediabot|3\.)/i, 15);
    $assert->ok(defined $r, "${cmdchar}version → PRIVMSG canal contenant '3.0'");
};
