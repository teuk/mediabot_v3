# t/cases/387_mb128_part_logout_and_purge_caches.t
# =============================================================================
# Tests des corrections mb128 :
#
#   - B1 : on_message_PART faisait $auth->logout($sNick) inconditionnellement
#          des qu'un user partait d'UN canal. Trop severe quand l'user est
#          present sur plusieurs canaux partages avec le bot. Apres ce fix
#          on ne logout que si le user n'est plus sur AUCUN autre canal.
#
# MB1104: purge cleanup is exercised natively by the MB933 fixture in case 386.
# =============================================================================

use strict;
use warnings;

my $case = sub {
    my ($assert) = @_;

    # -------------------------------------------------------------------------
    # B1: simulation de la decision logout-on-PART
    # -------------------------------------------------------------------------
    my $should_logout = sub {
        my ($hn, $sNick) = @_;
        my $lc_target = lc($sNick);
        return 1 unless ref($hn) eq 'HASH';
        OUTER: for my $chan (keys %$hn) {
            next unless ref($hn->{$chan}) eq 'ARRAY';
            for my $n (@{ $hn->{$chan} }) {
                if (lc($n) eq $lc_target) {
                    return 0;   # still present somewhere → don't logout
                }
            }
        }
        return 1;
    };

    # Cas 1: user sur 3 canaux, part de chanA -> reste sur 2 -> NO logout
    {
        # Apres channelNicksRemove(#chanA, Bob), Bob n'est plus dans chanA
        # mais reste dans chanB et chanC
        my $hn = {
            '#chanA' => ['Alice', 'Charlie'],    # Bob deja retire
            '#chanB' => ['Bob', 'Alice'],
            '#chanC' => ['Bob', 'Dave'],
        };
        $assert->($should_logout->($hn, 'Bob') == 0,
            "B1 Bob present on #chanB+#chanC -> do NOT logout");
    }

    # Cas 2: user sur 1 seul canal, part -> reste sur 0 -> LOGOUT
    {
        my $hn = {
            '#chanA' => ['Alice', 'Charlie'],    # Bob deja retire
        };
        $assert->($should_logout->($hn, 'Bob') == 1,
            "B1 Bob absent de tous canaux -> logout");
    }

    # Cas 3: case-insensitive matching (Bob/bob/BOB)
    {
        my $hn = {
            '#chanA' => ['alice'],
            '#chanB' => ['BOB', 'dave'],
        };
        $assert->($should_logout->($hn, 'Bob') == 0,
            "B1 case-insensitive match: BOB ~ Bob -> do NOT logout");
    }

    # Cas 4: hChannelNicks vide ou undef
    {
        $assert->($should_logout->({}, 'Bob') == 1,
            "B1 hash vide -> logout");
        $assert->($should_logout->(undef, 'Bob') == 1,
            "B1 undef -> logout");
    }

    # Cas 5: ARRAY vide pour un canal
    {
        my $hn = { '#chanA' => [], '#chanB' => [] };
        $assert->($should_logout->($hn, 'Bob') == 1,
            "B1 arrays vides -> logout");
    }


};

# ---------------------------------------------------------------------------
# Direct runner for standalone execution:
#   perl t/cases/THIS_FILE.t
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

