# t/live/21_ai.t
# =============================================================================
#  AI (OpenAI / Claude) — matrice live A2 (direction 3.3, §A2)
#  Couvre : !tellme <prompt> (OpenAI/ChatGPT) et !ai <prompt> (Claude).
#  Ces intégrations nécessitent une clé API. En test, la clé est presque
#  toujours ABSENTE : le contrat attendu est un message d'erreur/indisponible
#  PROPRE (clé manquante, non configuré, désactivé), jamais un crash ni un
#  secret loggé. On valide donc que la commande RÉPOND proprement.
#  Si une clé est réellement présente (instance de Christophe), une réponse
#  de contenu est aussi acceptée.
# =============================================================================

return sub {
    my ($assert, $spy, $send_cmd, $send_private, $wait_reply,
        $botnick, $spynick, $channel, $cmdchar,
        $loginuser, $loginpass, $drain) = @_;

    my $r;
    $drain->(3);

    # Contrat commun : le bot RÉPOND toujours (jamais de silence).
    #   - clé absente  -> "not configured" propre (mb468-B1) ;
    #   - clé présente -> une réponse de contenu quelconque.
    my $ai_reply = qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:\S)/i;

    # -------------------------------------------------------------------------
    # 1. !tellme <prompt> → réponse OpenAI OU "not configured" propre.
    # -------------------------------------------------------------------------
    $send_cmd->('tellme say the word pong');
    $r = $wait_reply->($ai_reply, 20);
    $assert->ok(defined $r, "${cmdchar}tellme → réponse OU not-configured (jamais de silence)");
    if (defined $r) {
        my $looks_like_key = ($r =~ /sk-[A-Za-z0-9]{16,}/);   # motif clé OpenAI
        $assert->ok(!$looks_like_key, 'tellme: aucune clé API exposée dans la réponse');
    }
    $drain->(3);

    # -------------------------------------------------------------------------
    # 2. !ai <prompt> → réponse Claude OU "not configured" propre.
    # -------------------------------------------------------------------------
    $send_cmd->('ai say the word pong');
    $r = $wait_reply->($ai_reply, 20);
    $assert->ok(defined $r, "${cmdchar}ai → réponse OU not-configured (jamais de silence)");
    if (defined $r) {
        my $looks_like_key = ($r =~ /sk-ant-[A-Za-z0-9\-]{16,}/);  # motif clé Anthropic
        $assert->ok(!$looks_like_key, 'ai: aucune clé API exposée dans la réponse');
    }
    $drain->(3);

    # -------------------------------------------------------------------------
    # 3. Non-régression : le bot reste réactif après les appels IA.
    # -------------------------------------------------------------------------
    $send_cmd->('version');
    $r = $wait_reply->(
        qr/PRIVMSG \Q$channel\E .*Mediabot version:/i, 10);
    $assert->ok(defined $r, 'le bot reste réactif après les commandes IA');
    $drain->(3);
};
