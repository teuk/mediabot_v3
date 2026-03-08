# t/live/02_commands.t
# =============================================================================
#  Tests des commandes publiques via IRC
#
#  Commandes testées : version, date, help, whoami (non auth)
# =============================================================================

return sub {
    my ($assert, $spy, $send_cmd, $send_private, $wait_reply,
        $botnick, $spynick, $channel, $cmdchar) = @_;

    my $cmd_reply = sub {
        my ($cmd, $pattern, $timeout) = @_;
        $timeout //= 15;
        $send_cmd->($cmd);
        return $wait_reply->(qr/(?:PRIVMSG|NOTICE) \Q$channel\E.*$pattern/i, $timeout);
    };

    my $priv_reply = sub {
        my ($cmd, $pattern, $timeout) = @_;
        $timeout //= 15;
        $send_private->($cmd);
        return $wait_reply->(qr/(?:PRIVMSG|NOTICE) \Q$spynick\E.*$pattern/i, $timeout);
    };

    # -------------------------------------------------------------------------
    # 1. !version → contient "mediabot" ou numéro de version
    # -------------------------------------------------------------------------
    my $r = $cmd_reply->('version', 'mediabot|3\\.0|version');
    $assert->ok(defined $r, "${cmdchar}version → réponse avec version");

    # -------------------------------------------------------------------------
    # 2. !date → réponse avec une date/heure
    # -------------------------------------------------------------------------
    $r = $cmd_reply->('date', '.');
    $assert->ok(defined $r, "${cmdchar}date → réponse non vide");

    # -------------------------------------------------------------------------
    # 3. !help → réponse (lien wiki ou liste)
    # -------------------------------------------------------------------------
    $r = $cmd_reply->('help', '.');
    $assert->ok(defined $r, "${cmdchar}help → réponse non vide");

    # -------------------------------------------------------------------------
    # 4. !whoami sur le canal sans être loggé → NOTICE au spynick
    #    (le bot répond en NOTICE au nick, pas PRIVMSG au canal)
    # -------------------------------------------------------------------------
    $send_cmd->('whoami');
    $r = $wait_reply->(qr/NOTICE \Q$spynick\E.*(?:logged|login|must|found|hostmask)/i, 15);
    $assert->ok(defined $r, "${cmdchar}whoami sans auth → notice d'erreur");

    # -------------------------------------------------------------------------
    # 5. Commande inconnue → bot toujours présent (vérifié par !version)
    # -------------------------------------------------------------------------
    $send_cmd->('zzz_unknown_command_xyz');
    sleep(2);
    $r = $cmd_reply->('version', 'mediabot|3\\.0|version');
    $assert->ok(defined $r, "Bot survit à une commande inconnue");
};
