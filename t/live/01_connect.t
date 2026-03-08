# t/live/01_connect.t
# =============================================================================
#  Tests de connexion IRC du bot
#
#  Vérifie :
#    - Le bot est présent sur le canal (JOIN déjà confirmé par test_live.pl)
#    - Le bot répond à !version
#    - Le bot est bien identifié avec le bon nick (WHOIS)
# =============================================================================

return sub {
    my ($assert, $spy, $send_cmd, $send_private, $wait_reply,
        $botnick, $spynick, $channel, $cmdchar) = @_;

    # -------------------------------------------------------------------------
    # 1. Le bot est présent sur le canal
    #    (le JOIN a déjà été confirmé par test_live.pl avant d'arriver ici)
    # -------------------------------------------------------------------------
    $assert->ok(1, "Bot '$botnick' a rejoint $channel");

    # -------------------------------------------------------------------------
    # 2. Le bot répond à !version
    # -------------------------------------------------------------------------
    $send_cmd->('version');
    my $ver = $wait_reply->(qr/PRIVMSG \Q$channel\E .*(?:mediabot|version|3\.0)/i, 15);
    $assert->ok(defined $ver, "Bot répond à ${cmdchar}version");

    # -------------------------------------------------------------------------
    # 3. Le bot porte bien le bon nick (WHOIS)
    # -------------------------------------------------------------------------
    $spy->send_raw("WHOIS $botnick");
    my $whois = $wait_reply->(qr/311 \Q$spynick\E \Q$botnick\E/i, 15);
    $assert->ok(defined $whois, "WHOIS confirme le nick '$botnick' sur IRC");
};
