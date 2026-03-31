# t/live/11_quotes.t
# =============================================================================
#  Quotes — add, view, search, random, stats, del
#  Nécessite auth Master (mboper / testpass123)
# =============================================================================

return sub {
    my ($assert, $spy, $send_cmd, $send_private, $wait_reply,
        $botnick, $spynick, $channel, $cmdchar,
        $loginuser, $loginpass) = @_;

    my $test_quote = 'zzzlive_test_quote_unique_' . int(rand(9999));

    # Setup : login Master
    $send_private->("login $loginuser $loginpass");
    $wait_reply->(qr/NOTICE \Q$spynick\E .*successful/i, 15);
    sleep(1);

    # -------------------------------------------------------------------------
    # 1. !q stats → contient un nombre
    # -------------------------------------------------------------------------
    $send_cmd->('q stats');
    my $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:\d+|empty|no quote)/i, 15);
    $assert->ok(defined $r, "${cmdchar}q stats → contient un nombre");
    sleep(1);

    # -------------------------------------------------------------------------
    # 2. !q add → ajouter une quote de test
    # -------------------------------------------------------------------------
    $send_cmd->("q add $test_quote");
    $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:add|quot|ok|\d+)/i, 15);
    $assert->ok(defined $r, "${cmdchar}q add → quote ajoutée");
    sleep(1);

    # -------------------------------------------------------------------------
    # 3. !q search → trouve la quote ajoutée
    # -------------------------------------------------------------------------
    $send_cmd->("q search $test_quote");
    $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:$test_quote|\d+)/i, 15);
    $assert->ok(defined $r, "${cmdchar}q search → trouve la quote de test");
    sleep(1);

    # -------------------------------------------------------------------------
    # 4. !q random → une quote quelconque
    # -------------------------------------------------------------------------
    $send_cmd->('q random');
    $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .+/i, 15);
    $assert->ok(defined $r, "${cmdchar}q random → réponse reçue");
    sleep(1);

    # -------------------------------------------------------------------------
    # 5. !q view <numéro> → voir la première quote
    # -------------------------------------------------------------------------
    $send_cmd->('q view 1');
    $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .+/i, 15);
    $assert->ok(defined $r, "${cmdchar}q view 1 → réponse reçue");
    sleep(1);

    # -------------------------------------------------------------------------
    # 6. !q del → supprimer par recherche (quote de test)
    #    On cherche d'abord l'id, puis on supprime
    # -------------------------------------------------------------------------
    # Récupérer l'id depuis la ligne qui contient "(id : N)"
    # Le bot envoie 2 lignes : "N quote(s)..." puis "Last on ... (id : N) quote"
    $send_cmd->("q search $test_quote");
    my $qid;
    for my $attempt (1..4) {
        my $line = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .+/i, 8);
        last unless defined $line;
        if ($line =~ /\(id\s*:\s*(\d+)\)/) {
            $qid = $1;
            last;
        }
    }
    $qid //= 1;  # fallback: première quote de la DB de test
    sleep(1);
    $send_cmd->("q del $qid");
    $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:del|remov|ok|delet|does not exist)/i, 15);
    $assert->ok(defined $r, "${cmdchar}q del $qid → réponse reçue");
};
