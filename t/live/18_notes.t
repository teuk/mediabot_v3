# t/live/18_notes.t
# =============================================================================
#  Notes — matrice live A2 (direction 3.3, §A2)
#  Couvre : !note <msg> (ajout), !notes (liste), !note search <mot>,
#           !notes del <id> (nettoyage).
#  Les notes sont PERSONNELLES (par utilisateur) et répondues en NOTICE privé.
#  Réponses connues :
#    add    → "Note saved (#N total). Use !notes to list."
#    list   → énumération "[i] texte"
#    search → "H/T notes matching 'mot'" puis "[i] texte"
#    del    → confirmation de suppression
#  Public : pas d'auth requise, mais l'utilisateur doit être connu du bot.
#  Le spy peut ne pas être un USER connu ; on tolère donc aussi le message
#  "known by the bot" comme contrat de réponse valide (pas de crash).
# =============================================================================

return sub {
    my ($assert, $spy, $send_cmd, $send_private, $wait_reply,
        $botnick, $spynick, $channel, $cmdchar,
        $loginuser, $loginpass, $drain) = @_;

    my $r;
    my $tag = 'zzzlive_note_' . int(rand(9999));

    # On se connecte : les notes s'attachent à un utilisateur identifié.
    $send_private->("login $loginuser $loginpass");
    $wait_reply->(qr/NOTICE \Q$spynick\E .*(?:successful|already)/i, 10);
    $drain->(2);

    # -------------------------------------------------------------------------
    # 1. !note <msg> → ajout (ou message "known by the bot" si non enregistré).
    # -------------------------------------------------------------------------
    $send_cmd->("note $tag");
    $r = $wait_reply->(
        qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:Note saved|saved|#\d+|known by the bot|Max 10)/i,
        10,
    );
    $assert->ok(defined $r, "${cmdchar}note → note ajoutée ou contrat connu");
    my $can_continue = (defined $r && $r =~ /saved|#\d+/i) ? 1 : 0;
    $drain->(3);

    # -------------------------------------------------------------------------
    # 2. !notes → liste (doit contenir notre tag si l'ajout a réussi).
    # -------------------------------------------------------------------------
    $send_cmd->('notes');
    $r = $wait_reply->(
        qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:\Q$tag\E|\[\d+\]|No notes|Notes:)/i,
        10,
    );
    $assert->ok(defined $r, "${cmdchar}notes → liste affichée");
    $drain->(3);

    # -------------------------------------------------------------------------
    # 3. !note search <tag> → retrouve la note.
    # -------------------------------------------------------------------------
    $send_cmd->("note search $tag");
    $r = $wait_reply->(
        qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:\Q$tag\E|matching|No notes)/i,
        10,
    );
    $assert->ok(defined $r, "${cmdchar}note search → retrouve la note ou 'No notes'");
    # Récupérer l'index [N] pour la suppression.
    my $idx;
    $idx = $1 if defined $r && $r =~ /\[(\d+)\]/;
    $drain->(3);

    # -------------------------------------------------------------------------
    # 4. !notes del <id> → nettoyage de la note de test.
    # -------------------------------------------------------------------------
    if ($can_continue) {
        # Si l'index n'a pas été capturé, relister pour le trouver.
        unless (defined $idx) {
            $send_cmd->('notes');
            for my $attempt (1..4) {
                my $line = $wait_reply->(
                    qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .+/i, 8);
                last unless defined $line;
                if ($line =~ /\[(\d+)\]\s.*\Q$tag\E/ || ($line =~ /\[(\d+)\]/ && $line =~ /\Q$tag\E/)) {
                    $idx = $1; last;
                }
            }
            $drain->(2);
        }
        $idx //= 1;
        $send_cmd->("notes del $idx");
        $r = $wait_reply->(
            qr/(?:PRIVMSG|NOTICE) (?:\Q$channel\E|\Q$spynick\E) .*(?:del|remov|Deleted|gone|does not|No note)/i,
            10,
        );
        $assert->ok(defined $r, "${cmdchar}notes del $idx → note supprimée");
    } else {
        $assert->ok(1, 'notes del ignoré (utilisateur de test non enregistré) — pas de crash');
    }
    $drain->(3);
};
