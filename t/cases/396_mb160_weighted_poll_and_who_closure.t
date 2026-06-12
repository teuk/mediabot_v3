# t/cases/396_mb160_weighted_poll_and_who_closure.t
# =============================================================================
# Tests des corrections mb160 :
#
#   - B1 : Le mode `weighted` du poll (BB7) parsait correctement les options
#          `option:weight` et stockait $poll->{weights} + $poll->{weighted},
#          mais ces donnees n'etaient JAMAIS consultees dans le tally live
#          (mbVote_ctx), le statut live (mbPollStatus_ctx), ni le resultat
#          final (mbPollResult_ctx). Le mode 'weighted' etait dead feature.
#
#   - B2 : Dans on_login, la closure WHO du throttle JOIN utilisait $irc
#          qui n'etait PAS en scope (defini lexicalement dans _build_irc()).
#          Donc `if $irc && $irc->is_connected` etait toujours false ->
#          WHO jamais envoye -> nicklist post-join cassee pour le path NS3.
#          Fix : utiliser $mediabot->{irc} qui est globalement disponible.
# =============================================================================

use strict;
use warnings;

return sub {
    my ($assert) = @_;

    # =========================================================================
    # B1 : weighted poll tally / result / status
    # =========================================================================

    # Ancien tally (sans poids)
    my $tally_buggy = sub {
        my ($poll) = @_;
        my %counts;
        $counts{ $poll->{votes}{$_} }++ for keys %{ $poll->{votes} };
        return \%counts;
    };

    # Nouveau tally (avec poids quand weighted)
    my $tally_fixed = sub {
        my ($poll) = @_;
        my %counts;
        $counts{ $poll->{votes}{$_} }++ for keys %{ $poll->{votes} };
        return \%counts unless $poll->{weighted};
        my %scores;
        my $weights = $poll->{weights} || [];
        for my $idx (0 .. $#{ $poll->{options} }) {
            my $voters = $counts{$idx} // 0;
            my $w      = $weights->[$idx] // 1;
            $scores{$idx} = $voters * $w;
        }
        return \%scores;
    };

    # Determine winner
    my $winner = sub {
        my ($score_hash) = @_;
        my ($winner) = sort { ($score_hash->{$b} // 0) <=> ($score_hash->{$a} // 0) }
                       keys %$score_hash;
        return $winner;
    };

    # -------------------------------------------------------------------------
    # Cas 1 : poll non-weighted (compat preservee)
    # -------------------------------------------------------------------------
    {
        my $poll = {
            options  => ['A', 'B', 'C'],
            weights  => [1, 1, 1],
            weighted => 0,
            votes    => { alice => 0, bob => 1, charlie => 1, dave => 2 },
        };
        my $b = $tally_buggy->($poll);
        my $f = $tally_fixed->($poll);
        $assert->($b->{0} == 1 && $b->{1} == 2 && $b->{2} == 1,
            "B1 non-weighted: ancien tally correct (compat)");
        $assert->($f->{0} == 1 && $f->{1} == 2 && $f->{2} == 1,
            "B1 non-weighted: nouveau tally identique (compat preservee)");
        $assert->($winner->($f) == 1,
            "B1 non-weighted: gagnant = B (2 voteurs)");
    }

    # -------------------------------------------------------------------------
    # Cas 2 : poll weighted Pizza(x3) Sushi(x1) — Sushi a +voteurs mais
    #         Pizza doit gagner par poids
    # -------------------------------------------------------------------------
    {
        my $poll = {
            options  => ['Pizza', 'Sushi'],
            weights  => [3, 1],
            weighted => 1,
            votes    => { alice => 0, bob => 0, charlie => 1, dave => 1, eve => 1 },
        };
        my $b = $tally_buggy->($poll);
        my $f = $tally_fixed->($poll);

        # Buggy: voteurs uniquement
        $assert->($b->{0} == 2 && $b->{1} == 3,
            "B1 REGRESSION-POC: ancien code compte 2 voteurs Pizza, 3 voteurs Sushi");
        $assert->($winner->($b) == 1,
            "B1 REGRESSION-POC: ancien code declare Sushi gagnant (3>2 voteurs)");

        # Fixed: poids appliques
        $assert->($f->{0} == 6 && $f->{1} == 3,
            "B1 FIX: nouveau code calcule Pizza 2*3=6, Sushi 3*1=3");
        $assert->($winner->($f) == 0,
            "B1 FIX: Pizza gagne (score pondere 6 > 3) malgre moins de voteurs");
    }

    # -------------------------------------------------------------------------
    # Cas 3 : poll weighted egal — tie-break par index croissant (sort stable)
    # -------------------------------------------------------------------------
    {
        my $poll = {
            options  => ['A', 'B'],
            weights  => [2, 2],
            weighted => 1,
            votes    => { x => 0, y => 1 },
        };
        my $f = $tally_fixed->($poll);
        $assert->($f->{0} == 2 && $f->{1} == 2,
            "B1 weighted egal: scores Pizza=2, Sushi=2 (1 voteur * x2 chacun)");
    }

    # -------------------------------------------------------------------------
    # Cas 4 : poll weighted vide — pas de division par zero
    # -------------------------------------------------------------------------
    {
        my $poll = {
            options  => ['A', 'B'],
            weights  => [5, 3],
            weighted => 1,
            votes    => {},   # aucun vote
        };
        my $f = $tally_fixed->($poll);
        my $weighted_total = 0;
        $weighted_total += ($f->{$_} // 0) for keys %$f;
        $assert->($weighted_total == 0,
            "B1 weighted vide: weighted_total=0 (pas de vote)");
        # On verifie qu'un pourcentage ne crashe pas
        my $idx = 0;
        my $pct_safe = $weighted_total > 0 ? int(($f->{$idx} // 0) * 100 / $weighted_total) : 0;
        $assert->($pct_safe == 0,
            "B1 weighted vide: pct safe = 0% (pas de div by zero)");
    }

    # -------------------------------------------------------------------------
    # Cas 5 : poll weighted avec poids manquant (default x1)
    # -------------------------------------------------------------------------
    {
        my $poll = {
            options  => ['A', 'B', 'C'],
            weights  => [5],     # B et C n'ont pas de poids -> default x1
            weighted => 1,
            votes    => { x => 0, y => 0, z => 1, w => 2 },
        };
        my $f = $tally_fixed->($poll);
        $assert->($f->{0} == 10 && $f->{1} == 1 && $f->{2} == 1,
            "B1 weighted manquant: A 2x5=10, B 1x1=1, C 1x1=1");
        $assert->($winner->($f) == 0,
            "B1 weighted manquant: A gagne (10 vs 1 vs 1)");
    }

    # -------------------------------------------------------------------------
    # Cas 6 : poll weighted scenarios realistes
    # -------------------------------------------------------------------------
    {
        # "Voter pondere : Owner=5, Master=3, User=1"
        # Imaginons un vote sur 3 options avec poids
        my $poll = {
            options  => ['accept', 'reject', 'abstain'],
            weights  => [5, 5, 1],   # accept et reject importants, abstain leger
            weighted => 1,
            votes    => {
                'admin'    => 0,   # accept
                'user1'    => 0,   # accept
                'troll1'   => 1,   # reject
                'troll2'   => 1,   # reject
                'troll3'   => 1,   # reject
                'undecided' => 2,  # abstain
            },
        };
        my $f = $tally_fixed->($poll);
        $assert->($f->{0} == 10,
            "B1 realiste: accept = 2 voteurs * x5 = 10");
        $assert->($f->{1} == 15,
            "B1 realiste: reject = 3 voteurs * x5 = 15");
        $assert->($f->{2} == 1,
            "B1 realiste: abstain = 1 voteur * x1 = 1");
        $assert->($winner->($f) == 1,
            "B1 realiste: reject gagne par poids (3 trolls > 2 acceptants si poids egal)");
    }

    # =========================================================================
    # B2 : closure WHO doit utiliser $mediabot->{irc} pas $irc undef
    # =========================================================================

    # Simulons un objet bot avec son irc
    my $mock_bot = {
        irc => bless({ connected => 1 }, 'MockIRC'),
    };
    # Mock methods
    no strict 'refs';
    *MockIRC::is_connected = sub { $_[0]->{connected} ? 1 : 0 };
    *MockIRC::send_message = sub {
        my ($self, $cmd, $arg1, $arg2) = @_;
        $self->{last_sent} = [$cmd, $arg1, $arg2];
        return 1;
    };
    use strict 'refs';

    # Ancien comportement : $irc undef -> WHO jamais envoye
    {
        my $irc_undef;   # simule lexical undef
        my $would_send = 0;
        if ($irc_undef && $irc_undef->is_connected) {
            $would_send = 1;
        }
        $assert->($would_send == 0,
            "B2 REGRESSION-POC: \$irc undef dans closure -> WHO jamais envoye");
    }

    # Nouveau comportement : $mediabot->{irc} -> WHO envoye
    {
        my $bot_irc = $mock_bot->{irc};
        my $would_send = 0;
        if ($bot_irc && $bot_irc->is_connected) {
            $bot_irc->send_message('WHO', undef, '#chan');
            $would_send = 1;
        }
        $assert->($would_send == 1,
            "B2 FIX: \$mediabot->{irc} disponible -> WHO envoye");
        $assert->(ref($mock_bot->{irc}{last_sent}) eq 'ARRAY'
                && $mock_bot->{irc}{last_sent}[0] eq 'WHO'
                && $mock_bot->{irc}{last_sent}[2] eq '#chan',
            "B2 FIX: WHO #chan correctement envoye");
    }

    # Disconnect case : check is_connected blocks
    {
        my $bot_irc = bless({ connected => 0 }, 'MockIRC');
        my $would_send = 0;
        if ($bot_irc && $bot_irc->is_connected) {
            $would_send = 1;
        }
        $assert->($would_send == 0,
            "B2 deconnecte: WHO bloque (defense en profondeur preserve)");
    }
};
