# t/live/15_games_smoke.t
# =============================================================================
# mb452 — Smoke live des commandes « fun/jeux » stateless.
#
# Couvre les handlers publics sans état persistant ni infra externe :
#   8ball, roll, flip, choose, morse, calc, slap.
# Ces commandes ne nécessitent pas d'authentification (comme 04_dispatch_public).
#
# On vérifie le CONTRAT DE RÉPONSE (contenu), pas juste la présence d'une ligne.
# Deux commandes sont déterministes et servent d'ancrage fort :
#   - morse SOS  -> "... --- ..."
#   - calc 2+2   -> "2+2 = 4"
# Les autres matchent leur signature de sortie stable.
# =============================================================================

return sub {
    my ($assert, $spy, $send_cmd, $send_private, $wait_reply,
        $botnick, $spynick, $channel, $cmdchar, $loginuser, $loginpass, $drain) = @_;

    my $r;

    # -------------------------------------------------------------------------
    # 1. morse SOS -> "... --- ..." (déterministe)
    # -------------------------------------------------------------------------
    $drain->(3);
    $send_cmd->('morse SOS');
    $r = $wait_reply->(
        qr/PRIVMSG \Q$channel\E .*\.\.\. --- \.\.\./,
        10,
    );
    $assert->ok(defined $r, "${cmdchar}morse SOS → '... --- ...' (encodage exact)");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 2. calc 2+2 -> "2+2 = 4" (déterministe, SafeCalc)
    # -------------------------------------------------------------------------
    $send_cmd->('calc 2+2');
    $r = $wait_reply->(
        qr/PRIVMSG \Q$channel\E .*2\+2\s*=\s*4\b/,
        10,
    );
    $assert->ok(defined $r, "${cmdchar}calc 2+2 → '2+2 = 4'");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 3. 8ball <question> -> "[8ball] <nick>: <réponse>"
    # -------------------------------------------------------------------------
    $send_cmd->('8ball will this test pass?');
    $r = $wait_reply->(
        qr/PRIVMSG \Q$channel\E .*\[8ball\].*\Q$spynick\E/i,
        10,
    );
    $assert->ok(defined $r, "${cmdchar}8ball → réponse '[8ball] <nick>: ...'");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 4. roll (sans arg) -> "<nick> rolled 1d6: N"
    # -------------------------------------------------------------------------
    $send_cmd->('roll');
    $r = $wait_reply->(
        qr/PRIVMSG \Q$channel\E .*rolled 1d6:\s*[1-6]\b/i,
        10,
    );
    $assert->ok(defined $r, "${cmdchar}roll → 'rolled 1d6: N' (1..6)");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 5. flip -> "<nick> flipped a coin: Heads!|Tails!"
    # -------------------------------------------------------------------------
    $send_cmd->('flip');
    $r = $wait_reply->(
        qr/PRIVMSG \Q$channel\E .*flipped a coin:\s*(?:Heads!|Tails!)/i,
        10,
    );
    $assert->ok(defined $r, "${cmdchar}flip → 'flipped a coin: Heads!/Tails!'");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 6. choose a | b -> "<nick>: I choose... <x>!"
    # -------------------------------------------------------------------------
    $send_cmd->('choose pizza | pasta');
    $r = $wait_reply->(
        qr/PRIVMSG \Q$channel\E .*I choose\.\.\.\s*(?:pizza|pasta)!/i,
        10,
    );
    $assert->ok(defined $r, "${cmdchar}choose a | b → 'I choose... pizza!/pasta!'");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 7. slap <cible> -> ACTION "slaps <cible> with ..."
    # -------------------------------------------------------------------------
    $send_cmd->('slap testbot');
    $r = $wait_reply->(
        qr/PRIVMSG \Q$channel\E .*slaps testbot with/i,
        10,
    );
    $assert->ok(defined $r, "${cmdchar}slap → ACTION 'slaps testbot with ...'");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 8. Le bot reste vivant après la série (non-régression)
    # -------------------------------------------------------------------------
    $send_cmd->('version');
    $r = $wait_reply->(
        qr/PRIVMSG \Q$channel\E .*(?:Mediabot|3\.)/i,
        10,
    );
    $assert->ok(defined $r, "après la série jeux, le bot répond toujours à ${cmdchar}version");
    $drain->(3);
};
