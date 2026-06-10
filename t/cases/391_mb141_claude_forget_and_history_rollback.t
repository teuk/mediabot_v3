# t/cases/391_mb141_claude_forget_and_history_rollback.t
# =============================================================================
# Tests des corrections mb141 :
#
#   - B1 : !ai forget ne purgeait que _claude_history + _claude_persona.
#          _claude_pinned (pin context) et _ai_last_active (persona auto-
#          reset timestamp DD5) survivaient. L'utilisateur s'attend a ce
#          que "forget" vide tout son etat AI, pas une partie seulement.
#
#   - B2 : claudeAI push le user message en history AVANT l'appel API.
#          Si l'API echoue (HTTP error, decode_json fail, structure
#          invalide), le user message reste orphelin. A la commande
#          suivante on a [...,user,user] et l'API Anthropic rejette
#          ("messages must alternate between user and assistant"). Le
#          fix rollback le user message si l'API a fail (en distinguant
#          via le role du dernier element : cache-hit push assistant avant
#          son return undef).
# =============================================================================

use strict;
use warnings;

my $case = sub {
    my ($assert) = @_;

    # -------------------------------------------------------------------------
    # B1 : !ai forget purge tous les caches lies a la session AI
    # -------------------------------------------------------------------------

    my $forget = sub {
        my ($state, $nick, $channel) = @_;
        my $chan_part   = (defined $channel ? $channel : '__private__');
        my $hist_key    = "$nick\x00$chan_part";
        my $persona_key = lc($nick) . "\x00" . $chan_part;
        my $aux_key     = lc($nick) . "\x00" . $chan_part;

        my $had = (exists $state->{_claude_history}{$hist_key}
                || exists $state->{_claude_persona}{$persona_key}
                || exists $state->{_claude_pinned}{$aux_key}
                || exists $state->{_ai_last_active}{$aux_key}) ? 1 : 0;

        delete $state->{_claude_history}{$hist_key};
        delete $state->{_claude_persona}{$persona_key};
        delete $state->{_claude_pinned}{$aux_key};
        delete $state->{_ai_last_active}{$aux_key};

        return $had;
    };

    # Setup: user 'Teuk' sur '#bots' avec tout setté
    {
        my $state = {
            _claude_history => {
                "Teuk\x00#bots"  => [{role=>'user',content=>'hi'}],
                "Alice\x00#bots" => [{role=>'user',content=>'hello'}],
            },
            _claude_persona => {
                "teuk\x00#bots"  => 'mode pirate',
                "alice\x00#bots" => 'mode sage',
            },
            _claude_pinned => {
                "teuk\x00#bots"  => 'remember: my pet is Talos',
                "alice\x00#bots" => 'pin alice',
            },
            _ai_last_active => {
                "teuk\x00#bots"  => 1000,
                "alice\x00#bots" => 1100,
            },
        };

        my $had = $forget->($state, 'Teuk', '#bots');
        $assert->($had == 1, "B1 forget detecte qu'il y avait du state");

        # Teuk : tout vide
        $assert->(!exists $state->{_claude_history}{"Teuk\x00#bots"},
            "B1 history Teuk purge");
        $assert->(!exists $state->{_claude_persona}{"teuk\x00#bots"},
            "B1 persona teuk purge");
        $assert->(!exists $state->{_claude_pinned}{"teuk\x00#bots"},
            "B1 pinned teuk purge (NOUVEAU dans mb141)");
        $assert->(!exists $state->{_ai_last_active}{"teuk\x00#bots"},
            "B1 ai_last_active teuk purge (NOUVEAU dans mb141)");

        # Alice : intact
        $assert->(exists $state->{_claude_history}{"Alice\x00#bots"},
            "B1 history Alice preserve");
        $assert->(exists $state->{_claude_persona}{"alice\x00#bots"},
            "B1 persona alice preserve");
        $assert->(exists $state->{_claude_pinned}{"alice\x00#bots"},
            "B1 pinned alice preserve");
        $assert->(exists $state->{_ai_last_active}{"alice\x00#bots"},
            "B1 ai_last_active alice preserve");
    }

    # forget sur etat vide → had=0
    {
        my $state = {
            _claude_history => {},
            _claude_persona => {},
            _claude_pinned => {},
            _ai_last_active => {},
        };
        my $had = $forget->($state, 'Bob', '#chan');
        $assert->($had == 0, "B1 forget sur etat vide -> had=0");
    }

    # forget en privé (chan undef)
    {
        my $state = {
            _claude_history => { "Bob\x00__private__" => [1] },
            _claude_pinned => { "bob\x00__private__" => 'pin' },
            _claude_persona => {},
            _ai_last_active => {},
        };
        my $had = $forget->($state, 'Bob', undef);
        $assert->($had == 1, "B1 forget en prive -> had=1");
        $assert->(!exists $state->{_claude_history}{"Bob\x00__private__"},
            "B1 prive: history purge");
        $assert->(!exists $state->{_claude_pinned}{"bob\x00__private__"},
            "B1 prive: pinned purge");
    }

    # -------------------------------------------------------------------------
    # B2 : rollback du user message en cas d'echec API
    # -------------------------------------------------------------------------

    my $rollback_if_orphan = sub {
        my ($history) = @_;
        if (ref($history) eq 'ARRAY'
            && @$history
            && ($history->[-1]{role} // '') eq 'user')
        {
            pop @$history;
            return 1;   # rolled back
        }
        return 0;
    };

    # Cas 1: API HTTP error apres push user → rollback
    {
        my $history = [
            { role => 'user',      content => 'first question' },
            { role => 'assistant', content => 'first answer' },
        ];
        # User envoie nouveau prompt
        push @$history, { role => 'user', content => 'oops API will fail' };
        # API echoue → return undef (sans push assistant)
        # Rollback :
        my $rolled = $rollback_if_orphan->($history);
        $assert->($rolled == 1, "B2 HTTP error -> rollback declenche");
        $assert->(scalar(@$history) == 2, "B2 history retour a 2 messages");
        $assert->($history->[-1]{role} eq 'assistant',
            "B2 history se termine par assistant");
        $assert->($history->[-1]{content} eq 'first answer',
            "B2 history contient toujours la 1ere reponse");
    }

    # Cas 2: cache hit (push assistant deja fait par _claude_send_and_parse, return undef)
    # → PAS de rollback car le top est 'assistant'
    {
        my $history = [
            { role => 'user',      content => 'first' },
            { role => 'assistant', content => 'first answer' },
            { role => 'user',      content => 'cached question' },
            { role => 'assistant', content => 'cached answer' },   # push par cache-hit
        ];
        # API "fail" (return undef) MAIS l'assistant est deja en place
        my $rolled = $rollback_if_orphan->($history);
        $assert->($rolled == 0, "B2 cache hit -> PAS de rollback (top est assistant)");
        $assert->(scalar(@$history) == 4, "B2 cache hit: history preserve");
    }

    # Cas 3: history vide -> no rollback, no crash
    {
        my $history = [];
        my $rolled = $rollback_if_orphan->($history);
        $assert->($rolled == 0, "B2 history vide -> pas de rollback");
        $assert->(scalar(@$history) == 0, "B2 history reste vide");
    }

    # Cas 4: history undef (defensive) -> no crash
    {
        my $history = undef;
        my $rolled = eval { $rollback_if_orphan->($history) };
        $assert->(!$@, "B2 history undef -> pas de crash");
        $assert->($rolled == 0, "B2 history undef -> pas de rollback");
    }

    # Cas 5: regression POC — sans le rollback, on aurait deux user consecutifs
    {
        my $history = [
            { role => 'user',      content => 'Q1' },
            { role => 'assistant', content => 'A1' },
        ];
        # User envoie Q2, API fail, PAS de rollback (ancien code)
        push @$history, { role => 'user', content => 'Q2 fail' };
        # Next round: user envoie Q3
        push @$history, { role => 'user', content => 'Q3' };

        # Verifier qu'on a bien deux user consecutifs (qui ferait crash l'API Anthropic)
        my $consec_user = 0;
        for my $i (1..$#$history) {
            $consec_user++ if ($history->[$i-1]{role} // '') eq 'user'
                           && ($history->[$i]{role}   // '') eq 'user';
        }
        $assert->($consec_user > 0,
            "B2 REGRESSION-POC: sans rollback, 2 'user' consecutifs (rejet API)");
    }

    # Cas 6: complete scenario - 3 rounds avec 1 erreur au milieu
    {
        my $history = [];

        # Round 1: succes
        push @$history, { role => 'user',      content => 'Q1' };
        # API ok, push assistant
        push @$history, { role => 'assistant', content => 'A1' };

        # Round 2: API fail
        push @$history, { role => 'user',      content => 'Q2 fail' };
        # return undef, rollback
        $rollback_if_orphan->($history);

        # Round 3: succes
        push @$history, { role => 'user',      content => 'Q3' };
        push @$history, { role => 'assistant', content => 'A3' };

        # Verifier : pas de user consecutif
        my $consec = 0;
        for my $i (1..$#$history) {
            $consec++ if ($history->[$i-1]{role} // '') eq 'user'
                      && ($history->[$i]{role}   // '') eq 'user';
        }
        $assert->($consec == 0,
            "B2 scenario 3 rounds avec 1 erreur : pas de user consecutifs avec rollback");
        $assert->(scalar(@$history) == 4,
            "B2 scenario 3 rounds : history = 4 messages (Q1+A1+Q3+A3, Q2 fail rollbacked)");
    }
};

# ---------------------------------------------------------------------------
# Direct runner for standalone execution:
#   perl t/cases/391_mb141_claude_forget_and_history_rollback.t
#
# When loaded by the project harness, return the case coderef.
# ---------------------------------------------------------------------------
if (caller) {
    return $case;
}

my $tests = 0;
my $fail  = 0;

my $assert = sub {
    my ($ok, $name) = @_;
    $tests++;
    $name = 'unnamed assertion' unless defined $name && $name ne '';

    if ($ok) {
        print "ok $tests - $name\n";
    }
    else {
        print "not ok $tests - $name\n";
        $fail++;
    }
};

$case->($assert);
print "1..$tests\n";
exit($fail ? 1 : 0);

