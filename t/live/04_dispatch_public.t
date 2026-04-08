# t/live/04_dispatch_public.t
# =============================================================================
#  Dispatch public — une commande par famille de handler.
#  On vérifie le contenu des réponses, pas juste qu'il y en a une.
# =============================================================================

return sub {
    my ($assert, $spy, $send_cmd, $send_private, $wait_reply,
        $botnick, $spynick, $channel, $cmdchar,
        $loginuser, $loginpass, $drain) = @_;

    # -------------------------------------------------------------------------
    # 1. !help sans arg → contient l'URL du wiki
    # -------------------------------------------------------------------------
    $send_cmd->('help');
    my $r = $wait_reply->(qr/PRIVMSG \Q$channel\E .*github\.com.*wiki/i, 15);
    $assert->ok(defined $r, "${cmdchar}help → URL wiki dans la réponse");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 2. !help avec arg → contient "not available" et le nom de la commande
    # -------------------------------------------------------------------------
    $send_cmd->('help foobar');
    $r = $wait_reply->(qr/PRIVMSG \Q$channel\E .*(?:not available|foobar)/i, 15);
    $assert->ok(defined $r, "${cmdchar}help foobar → 'not available' ou 'foobar'");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 3. !q sans arg → notice contenant la syntaxe d'aide
    #    mbQuotes_ctx sans arg appelle _printQuoteSyntax → 7 NOTICE au nick
    #    On attend le premier, puis on draine les 6 restants
    # -------------------------------------------------------------------------
    $send_cmd->('q');
    $r = $wait_reply->(qr/NOTICE \Q$spynick\E .+/i, 15);
    $assert->ok(defined $r, "${cmdchar}q sans arg → NOTICE au nick (syntaxe)");
    $drain->(10);   # absorber les 6 NOTICE restants de _printQuoteSyntax

    # -------------------------------------------------------------------------
    # 4. Nick triggered "how old are you" → réponse contient une année (naissance)
    # -------------------------------------------------------------------------
    $spy->send_raw("PRIVMSG $channel :$botnick how old are you");
    sleep(1);
    $r = $wait_reply->(qr/PRIVMSG \Q$channel\E .*\b20(1[5-9]|[2-9]\d)\b/i, 15);
    $assert->ok(defined $r, "nick triggered 'how old are you' → année de naissance");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 5. Nick triggered "who is StatiK" → contient "StatiK" et "brother"
    # -------------------------------------------------------------------------
    $spy->send_raw("PRIVMSG $channel :$botnick who is StatiK");
    sleep(1);
    $r = $wait_reply->(qr/PRIVMSG \Q$channel\E .*StatiK.*brother|brother.*StatiK/i, 15);
    $assert->ok(defined $r, "nick triggered 'who is StatiK' → 'StatiK' + 'brother'");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 6. Nick triggered "who is your daddy" → contient "daddy" et "Te[u]K"
    # -------------------------------------------------------------------------
    $spy->send_raw("PRIVMSG $channel :$botnick who is your daddy");
    sleep(1);
    $r = $wait_reply->(qr/PRIVMSG \Q$channel\E .*(?:daddy|Te\[u\]K)/i, 15);
    $assert->ok(defined $r, "nick triggered 'who is your daddy' → 'daddy' ou 'Te[u]K'");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 7. Commande inconnue → pas de crash (bot répond toujours à !version)
    # -------------------------------------------------------------------------
    $send_cmd->('zzz_unknown_xyz');
    sleep(1);
    $send_cmd->('version');
    $r = $wait_reply->(qr/PRIVMSG \Q$channel\E .*3\.0/i, 15);
    $assert->ok(defined $r, "commande inconnue → bot toujours vivant");
};
