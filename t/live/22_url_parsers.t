# t/live/22_url_parsers.t
# =============================================================================
#  URL parsers — matrice live A2 (direction 3.3, §A2)
#  Le titrage d'URL et la détection YouTube sont des comportements PASSIFS
#  déclenchés par un message contenant un lien, gated par le chanset +UrlTitle.
#  Ils dépendent d'un fetch réseau sortant : en test on ne peut pas garantir
#  la récupération du titre. L'objectif live A2 est donc de vérifier :
#    1. l'activation propre du chanset +UrlTitle (contrat de config) ;
#    2. la NON-RÉGRESSION : poster une URL (y compris les faux positifs
#       corrigés en mb461/mb464) ne fait pas planter ni taire le bot ;
#    3. la robustesse sur une URL YouTube-like étrangère (mb464-B2) : aucune
#       fausse extraction ne doit perturber le bot.
#  Aucune assertion ne dépend d'un titre effectivement récupéré.
#  Master requis pour chanset ; on se logue.
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
    # 1. Activer +UrlTitle sur le canal (contrat de config propre).
    # -------------------------------------------------------------------------
    $send_cmd->("chanset $channel +UrlTitle");
    $r = $wait_reply->(
        qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:Chanset \+UrlTitle (?:applied|is already set)|UrlTitle)/i,
        10,
    );
    $assert->ok(defined $r, "${cmdchar}chanset +UrlTitle → activé proprement");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 2. Poster une VRAIE URL : le bot ne doit ni crasher ni se taire.
    #    On envoie un message normal (pas une commande) dans le canal.
    #    On vérifie ensuite la réactivité par une commande de contrôle.
    # -------------------------------------------------------------------------
    $spy->privmsg($channel, 'regardez https://example.org/ un lien neutre');
    $drain->(5);   # laisser le temps au parseur passif (fetch best-effort)

    $send_cmd->('version');
    $r = $wait_reply->(qr/PRIVMSG \Q$channel\E .*Mediabot version:/i, 10);
    $assert->ok(defined $r, 'le bot reste réactif après une URL réelle');
    $drain->(3);

    # -------------------------------------------------------------------------
    # 3. Faux positif YouTube (mb464-B2) : host étranger avec ?v=<id>.
    #    Ne doit PAS être traité comme YouTube ; surtout, aucun crash.
    # -------------------------------------------------------------------------
    $spy->privmsg($channel, 'faux positif https://example.org/?v=dQw4w9WgXcQ test');
    $drain->(5);

    $send_cmd->('version');
    $r = $wait_reply->(qr/PRIVMSG \Q$channel\E .*Mediabot version:/i, 10);
    $assert->ok(defined $r, 'le bot reste réactif après une URL YouTube-like étrangère (mb464-B2)');
    $drain->(3);

    # -------------------------------------------------------------------------
    # 4. Nettoyage : remettre le canal dans son état par défaut (-UrlTitle).
    # -------------------------------------------------------------------------
    $send_cmd->("chanset $channel -UrlTitle");
    $r = $wait_reply->(
        qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:Chanset -UrlTitle (?:removed|is not set)|UrlTitle)/i,
        10,
    );
    $assert->ok(defined $r, "${cmdchar}chanset -UrlTitle → désactivé (nettoyage)");
    $drain->(3);
};
