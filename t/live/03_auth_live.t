# t/live/03_auth_live.t
# =============================================================================
#  Tests d'authentification et de contrôle des droits via IRC réel
#
#  Le user "mbtest" existe dans mediabot_test avec :
#    - id_user_level = 1 (Owner)
#    - username = #AUTOLOGIN#
#    - hostmask = *mbtest@*
#
#  Le spy a le nick $spynick — il n'est PAS dans la DB donc non authentifié.
#
#  Messages exacts du bot (d'après Context.pm / userLogin_ctx) :
#    - require_level sans auth  → "You must be logged in to use this command."
#    - require_level mauvais nv → "Your level does not allow you to use this command."
#    - !login mauvais pass      → "Login failed (Bad password)."
#    - !whoami sans auth        → "You must be logged in: /msg ..."
# =============================================================================

return sub {
    my ($assert, $spy, $send_cmd, $send_private, $wait_reply,
        $botnick, $spynick, $channel, $cmdchar) = @_;

    my $priv_notice = sub {
        my ($cmd, $pattern, $timeout) = @_;
        $timeout //= 15;
        $send_private->($cmd);
        return $wait_reply->(qr/NOTICE \Q$spynick\E.*(?:$pattern)/i, $timeout);
    };

    my $chan_reply = sub {
        my ($cmd, $pattern, $timeout) = @_;
        $timeout //= 15;
        $send_cmd->($cmd);
        return $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E).*(?:$pattern)/i, $timeout);
    };

    # -------------------------------------------------------------------------
    # 1. !die sans auth → "You must be logged in to use this command."
    # -------------------------------------------------------------------------
    my $r = $chan_reply->('die', 'logged|level|allow|must');
    $assert->ok(defined $r, "${cmdchar}die sans auth → refus");

    # -------------------------------------------------------------------------
    # 2. Login avec mauvais mot de passe → "Login failed (Bad password)."
    #    Envoyé en PRIVMSG au bot sans cmdchar : "login mbtest wrongpassword"
    # -------------------------------------------------------------------------
    $send_private->('login nosuchuser_xyz wrongpassword');
    $r = $wait_reply->(qr/NOTICE \Q$spynick\E.*(?:fail|unknown|not found|bad|wrong|invalid)/i, 15);
    $assert->ok(defined $r, "login user inconnu → refus");

    # -------------------------------------------------------------------------
    # 3. !whoami sur le canal sans auth → NOTICE au spynick
    # -------------------------------------------------------------------------
    $send_cmd->('whoami');
    $r = $wait_reply->(qr/NOTICE \Q$spynick\E.*(?:logged|login|must|found|hostmask)/i, 15);
    $assert->ok(defined $r, "${cmdchar}whoami → notice d'erreur (non auth)");

    # -------------------------------------------------------------------------
    # 4. !die sur le canal par spy (non loggé) → refus niveau ou auth
    # -------------------------------------------------------------------------
    $r = $chan_reply->('die test', 'logged|level|allow|must');
    $assert->ok(defined $r, "${cmdchar}die (non auth) → refus");

    # -------------------------------------------------------------------------
    # 5. Bot toujours vivant après tous ces tests → !version répond
    # -------------------------------------------------------------------------
    $send_cmd->('version');
    $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) \Q$channel\E.*(?:mediabot|3\.0|version)/i, 15);
    $assert->ok(defined $r, "Bot toujours vivant après les tests d'auth");
};
