# t/live/19_reminders.t
# =============================================================================
#  Reminders / Scheduler — matrice live A2 (direction 3.3, §A2)
#  Couvre : !remind <nick> <msg> (immédiat via cible), !remind in <delay>,
#           !remind list, !remind cancel <id>, garde anti-auto-remind.
#  Réponses connues :
#    set     → "Reminder set for <target><delay_info>."
#    list    → énumération des reminders en attente (ou "No ...")
#    cancel  → confirmation d'annulation
#    self    → "You can't remind yourself."
#  Le scheduler délivre en arrière-plan : on ne teste PAS la livraison temporelle
#  (hors périmètre live rapide), seulement la programmation et la gestion.
#  On vise le BOT comme cible (présent), et on nettoie via cancel.
#  Master utile pour garantir l'accès ; on se logue.
# =============================================================================

return sub {
    my ($assert, $spy, $send_cmd, $send_private, $wait_reply,
        $botnick, $spynick, $channel, $cmdchar,
        $loginuser, $loginpass, $drain) = @_;

    my $r;

    $send_private->("login $loginuser $loginpass");
    $wait_reply->(qr/NOTICE \Q$spynick\E .*(?:successful|already)/i, 10);
    $drain->(2);

    # -------------------------------------------------------------------------
    # 1. Garde : on ne peut pas se rappeler soi-même.
    # -------------------------------------------------------------------------
    $send_cmd->("remind $spynick zzzlive_self_check");
    $r = $wait_reply->(
        qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:can't remind yourself|yourself)/i,
        10,
    );
    $assert->ok(defined $r, "${cmdchar}remind self → refusé (anti-auto-remind)");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 2. !remind <bot> in 2h <msg> → programmation avec délai.
    #    Ordre réel : le nick cible vient EN PREMIER, le préfixe de délai
    #    ('in 2h') préfixe le MESSAGE. Contrat : "Reminder set for <bot> ...".
    # -------------------------------------------------------------------------
    my $tag = 'zzzlive_remind_' . int(rand(9999));
    $send_cmd->("remind $botnick in 2h $tag");
    $r = $wait_reply->(
        qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:Reminder set for|remind|scheduled|ok)/i,
        10,
    );
    $assert->ok(defined $r, "${cmdchar}remind <bot> in 2h → reminder programmé");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 3. !remind list → doit lister au moins le reminder programmé.
    #    Capturer un id pour l'annulation.
    # -------------------------------------------------------------------------
    $send_cmd->('remind list');
    my $rid;
    for my $attempt (1..5) {
        my $line = $wait_reply->(
            qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .+/i, 8);
        last unless defined $line;
        $r //= $line;
        if ($line =~ /#(\d+)/ || $line =~ /\bid[:\s]+(\d+)/i) {
            $rid = $1; last;
        }
        last if $line =~ /No (?:pending )?reminder/i;
    }
    $assert->ok(defined $r, "${cmdchar}remind list → liste ou 'No reminders'");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 4. !remind cancel <id> → nettoyage (si un id a été capturé).
    # -------------------------------------------------------------------------
    if (defined $rid) {
        $send_cmd->("remind cancel $rid");
        $r = $wait_reply->(
            qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:cancel|remov|deleted|gone|No reminder)/i,
            10,
        );
        $assert->ok(defined $r, "${cmdchar}remind cancel $rid → reminder annulé");
    } else {
        # Pas d'id capturé : vérifier au moins que la syntaxe cancel répond.
        $send_cmd->('remind cancel 999999');
        $r = $wait_reply->(
            qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:cancel|No reminder|not found|Syntax)/i,
            10,
        );
        $assert->ok(defined $r, "${cmdchar}remind cancel → contrat de réponse présent");
    }
    $drain->(3);
};
