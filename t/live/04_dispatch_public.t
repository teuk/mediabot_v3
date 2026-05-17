# t/live/04_dispatch_public.t
# =============================================================================
# Dispatch public — une commande par famille de handler.
# On vérifie le contenu des réponses, pas juste qu'il y en a une.
# =============================================================================

return sub {
    my ($assert, $spy, $send_cmd, $send_private, $wait_reply,
        $botnick, $spynick, $channel, $cmdchar,
        $loginuser, $loginpass, $drain) = @_;

    my $r;

    # -------------------------------------------------------------------------
    # 1. !help sans arg → NOTICE au nick
    #
    # Selon le niveau/auth du spy, le premier bloc peut contenir :
    #   - "Level   0: ..."
    #   - "Available commands on #channel ..."
    #   - "Level 500: ..."
    #
    # Le comportement important est :
    #   - help ne flood pas le channel ;
    #   - help répond par NOTICE au nick ;
    #   - le contenu ressemble à une liste de commandes/niveaux.
    # -------------------------------------------------------------------------
    $drain->(3);
    $send_cmd->('help');

    $r = $wait_reply->(
        qr/NOTICE \Q$spynick\E .*(?:Available commands|Level\s+\d+\s*:|access\s+chaninfo\s+login)/i,
        20
    );

    $assert->ok(defined $r, "${cmdchar}help → NOTICE avec liste d'aide");
    $drain->(8);

    # -------------------------------------------------------------------------
    # 2. !help avec arg inconnu → NOTICE au nick avec le nom cherché
    # -------------------------------------------------------------------------
    $send_cmd->('help foobar');

    $r = $wait_reply->(
        qr/NOTICE \Q$spynick\E .*(?:No internal help|PUBLIC_COMMANDS|foobar|Documentation)/i,
        20
    );

    $assert->ok(defined $r, "${cmdchar}help foobar → NOTICE avec foobar");
    $drain->(8);

    # -------------------------------------------------------------------------
    # 3. !q sans arg → NOTICE contenant la syntaxe d'aide
    #
    # _printQuoteSyntax envoie plusieurs NOTICE. On attend la première ligne,
    # puis on draine large pour éviter que les lignes restantes polluent le test
    # suivant.
    # -------------------------------------------------------------------------
    $send_cmd->('q');

    $r = $wait_reply->(
        qr/NOTICE \Q$spynick\E .*(?:Quotes syntax|q \[add|q \[del|q stats)/i,
        20
    );

    $assert->ok(defined $r, "${cmdchar}q sans arg → NOTICE au nick (syntaxe)");

    # Il y a plusieurs lignes de syntaxe. On draine volontairement large.
    $drain->(15);
    sleep(1);

    # -------------------------------------------------------------------------
    # 4. Nick triggered "how old are you" → réponse d'âge du bot
    #
    # On matche le sens de la réponse plutôt qu'une année trop stricte.
    # -------------------------------------------------------------------------
    $spy->send_raw("PRIVMSG $channel :$botnick how old are you");

    $r = $wait_reply->(
        qr/PRIVMSG \Q$channel\E .*(?:I was born|years?.*old|born on)/i,
        20
    );

    $assert->ok(defined $r, "nick triggered 'how old are you' → réponse d'âge");
    $drain->(5);

    # -------------------------------------------------------------------------
    # 5. Nick triggered "who is StatiK" → contient "StatiK" et "brother"
    # -------------------------------------------------------------------------
    $spy->send_raw("PRIVMSG $channel :$botnick who is StatiK");

    $r = $wait_reply->(
        qr/PRIVMSG \Q$channel\E .*(?:StatiK.*brother|brother.*StatiK)/i,
        20
    );

    $assert->ok(defined $r, "nick triggered 'who is StatiK' → 'StatiK' + 'brother'");
    $drain->(5);

    # -------------------------------------------------------------------------
    # 6. Nick triggered "who is your daddy" → contient "daddy" ou "Te[u]K"
    # -------------------------------------------------------------------------
    $spy->send_raw("PRIVMSG $channel :$botnick who is your daddy");

    $r = $wait_reply->(
        qr/PRIVMSG \Q$channel\E .*(?:daddy|Te\[u\]K)/i,
        20
    );

    $assert->ok(defined $r, "nick triggered 'who is your daddy' → 'daddy' ou 'Te[u]K'");
    $drain->(5);

    # -------------------------------------------------------------------------
    # 7. Commande inconnue → pas de crash, le bot répond toujours à !version
    # -------------------------------------------------------------------------
    $send_cmd->('zzz_unknown_xyz');
    $drain->(3);

    $send_cmd->('version');

    $r = $wait_reply->(
        qr/PRIVMSG \Q$channel\E .*(?:Mediabot|3\.)/i,
        20
    );

    $assert->ok(defined $r, "commande inconnue → bot toujours vivant");
    $drain->(3);
};
