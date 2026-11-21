# t/cases/385_mb124_quote_random_and_like_escape.t
# =============================================================================
# Tests des corrections mb124 :
#   - B1 : le tirage sans répétition est testé via la commande native dans
#          255_quotes_bynick.t, y compris après suppression du dernier tirage.
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
