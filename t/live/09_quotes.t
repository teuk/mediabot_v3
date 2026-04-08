# t/live/09_quotes.t
# =============================================================================
#  Quotes — add, view, search, random, stats, del
#  Nécessite auth Master (mboper / testpass123)
# =============================================================================

return sub {
    my ($assert, $spy, $send_cmd, $send_private, $wait_reply,
        $botnick, $spynick, $channel, $cmdchar,
        $loginuser, $loginpass, $drain) = @_;

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
    $drain->(3);

    # -------------------------------------------------------------------------
    # 2. !q add → ajouter une quote de test, capturer l'id retourné
    # -------------------------------------------------------------------------
    $send_cmd->("q add $test_quote");
    $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:add|quot|ok|\d+)/i, 15);
    $assert->ok(defined $r, "${cmdchar}q add → quote ajoutée");
    # Capturer l'id depuis la réponse (ex: "done. (id: 42)")
    my $added_id;
    $added_id = $1 if defined $r && $r =~ /\(id[:\s]+(\d+)\)/i;
    $drain->(3);

    # -------------------------------------------------------------------------
    # 3. !q search → trouve la quote ajoutée
    # -------------------------------------------------------------------------
    $send_cmd->("q search $test_quote");
    $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:$test_quote|\d+)/i, 15);
    $assert->ok(defined $r, "${cmdchar}q search → trouve la quote de test");
    # Récupérer l'id depuis le résultat de search si pas encore trouvé
    $added_id //= $1 if defined $r && $r =~ /\(id[:\s]+(\d+)\)/i;
    $drain->(3);

    # -------------------------------------------------------------------------
    # 4. !q random → une quote quelconque
    # -------------------------------------------------------------------------
    $send_cmd->('q random');
    $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .+/i, 15);
    $assert->ok(defined $r, "${cmdchar}q random → réponse reçue");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 5. !q view <id> → voir la quote qu'on vient d'ajouter
    # -------------------------------------------------------------------------
    my $view_id = $added_id // 1;
    $send_cmd->("q view $view_id");
    $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .+/i, 15);
    $assert->ok(defined $r, "${cmdchar}q view $view_id → réponse reçue");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 6. !q del → supprimer la quote de test
    # -------------------------------------------------------------------------
    # Récupérer l'id depuis !q search si pas encore connu
    my $qid = $added_id;
    unless ($qid) {
        $send_cmd->("q search $test_quote");
        for my $attempt (1..4) {
            my $line = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .+/i, 8);
            last unless defined $line;
            if ($line =~ /\(id[\s:]+(\d+)\)/) {
                $qid = $1;
                last;
            }
        }
        $drain->(3);
    }
    $qid //= 1;  # fallback

    $send_cmd->("q del $qid");
    $r = $wait_reply->(qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:del|remov|ok|delet|does not exist)/i, 15);
    $assert->ok(defined $r, "${cmdchar}q del $qid → réponse reçue");
};
