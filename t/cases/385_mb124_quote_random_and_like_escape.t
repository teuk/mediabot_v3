# t/cases/385_mb124_quote_random_and_like_escape.t
# =============================================================================
# Tests des corrections mb124 :
#   - B1 : mbQuoteRand anti-doublon casse. Avant ce fix, la boucle
#          `for (1..5) { ... last if $candidate_offset != $offset; ... }`
#          comparait deux randoms entre eux sans aucun lien avec $last_id,
#          donc la prevention "deux fois de suite la meme quote" ne
#          fonctionnait pas. Apres ce fix on exclut directement $last_id
#          via WHERE q.id_quotes != ? dans la requete SQL.
#   - B2 : Les 5 LIKE de Quotes.pm n'echappaient pas les wildcards SQL
#          (_ et %), alors que `_` est un caractere valide dans les nicks
#          IRC (RFC 2812). Un nick `bob_` matchait `boba`, `bobx`, etc.
#          par accident. Maintenant on escape avec ESCAPE '!'.
# =============================================================================

use strict;
use warnings;

return sub {
    my ($assert) = @_;

    # -------------------------------------------------------------------------
    # B1 : mbQuoteRand exclude_last decision
    # -------------------------------------------------------------------------
    my $rand_decision = sub {
        my ($count, $last_id) = @_;
        my $exclude_last    = (defined $last_id && $count > 1) ? 1 : 0;
        my $effective_count = $exclude_last ? ($count - 1) : $count;
        $effective_count = 1 if $effective_count < 1;
        return ($exclude_last, $effective_count);
    };

    my @b1_cases = (
        # count  last_id  exp_exclude  exp_effective_count
        [10, undef, 0, 10],   # premier appel
        [10, 5,     1, 9],    # 2e appel, on exclut 1 quote
        [1,  undef, 0, 1],    # une seule quote, premier appel
        [1,  3,     0, 1],    # une seule quote: NE PAS exclure (sinon 0 rows)
        [2,  1,     1, 1],    # 2 quotes, last_id=1 -> 1 candidate restant
        [100, 42,   1, 99],   # gros set
    );
    for my $c (@b1_cases) {
        my ($count, $last_id, $exp_excl, $exp_eff) = @$c;
        my ($got_excl, $got_eff) = $rand_decision->($count, $last_id);
        my $tag = sprintf("count=%d last=%s",
            $count, (defined $last_id ? $last_id : 'undef'));
        $assert->($got_excl == $exp_excl,
            "B1 $tag -> exclude=$exp_excl (got $got_excl)");
        $assert->($got_eff == $exp_eff,
            "B1 $tag -> effective_count=$exp_eff (got $got_eff)");
    }

    # -------------------------------------------------------------------------
    # B2 : SQL LIKE wildcard escape
    # -------------------------------------------------------------------------
    my $escape_like = sub {
        my ($input) = @_;
        my $t = lc($input);
        $t =~ s/!/!!/g;
        $t =~ s/%/!%/g;
        $t =~ s/_/!_/g;
        return $t;
    };

    my @b2_cases = (
        # input         expected_escaped
        ['bob',         'bob'],
        ['bob_',        'bob!_'],
        ['__user__',    '!_!_user!_!_'],
        ['a%b',         'a!%b'],
        ['with!bang',   'with!!bang'],
        ['plain',       'plain'],
        ['UPPER',       'upper'],            # lc applied
        ['Mix_Case',    'mix!_case'],        # lc + escape
        ['100%',        '100!%'],
    );
    for my $c (@b2_cases) {
        my ($input, $expected) = @$c;
        my $got = $escape_like->($input);
        $assert->($got eq $expected,
            "B2 escape '$input' -> '$expected' (got '$got')");
    }

    # -------------------------------------------------------------------------
    # B2 (semantique) : simuler le matching apres escape
    # On verifie qu'un pattern echappe ne matche que ce qu'il faut.
    # -------------------------------------------------------------------------
    # Simulation simplifiee du comportement MySQL LIKE avec ESCAPE '!':
    #   - !% -> literal %
    #   - !_ -> literal _
    #   - !! -> literal !
    #   - %  -> any sequence
    #   - _  -> any single char
    my $sql_like_match = sub {
        my ($pattern, $value, $escape) = @_;
        $escape //= '!';
        # Build a regex from the LIKE pattern, honoring ESCAPE
        my $re = '';
        my $i = 0;
        my $len = length($pattern);
        while ($i < $len) {
            my $c = substr($pattern, $i, 1);
            if ($c eq $escape && $i + 1 < $len) {
                my $next = substr($pattern, $i + 1, 1);
                $re .= quotemeta($next);
                $i += 2;
            }
            elsif ($c eq '%') { $re .= '.*'; $i++; }
            elsif ($c eq '_') { $re .= '.';  $i++; }
            else              { $re .= quotemeta($c); $i++; }
        }
        return $value =~ /\A${re}\z/i ? 1 : 0;
    };

    # Cas critique : nick 'bob_' ne doit matcher QUE 'bob_' et 'bob_xxx'
    # (avec wildcard suffix), pas 'boba'.
    my $pat = $escape_like->('bob_') . '%';   # 'bob!_%'
    $assert->($sql_like_match->($pat, 'bob_')      == 1, "B2 SEM 'bob!_%' matches 'bob_'");
    $assert->($sql_like_match->($pat, 'bob_test')  == 1, "B2 SEM 'bob!_%' matches 'bob_test'");
    $assert->($sql_like_match->($pat, 'boba')      == 0, "B2 SEM 'bob!_%' does NOT match 'boba'");
    $assert->($sql_like_match->($pat, 'bobx')      == 0, "B2 SEM 'bob!_%' does NOT match 'bobx'");

    # Sans escape, l'ancien comportement aurait fait :
    #   'bob_%' (sans ESCAPE) matcherait 'boba', 'bobx', etc.
    my $pat_unescaped = 'bob_%';
    $assert->($sql_like_match->($pat_unescaped, 'boba', undef) == 1,
        "B2 OLD 'bob_%' (no ESCAPE) WOULD match 'boba' [proves the original bug]");
};
