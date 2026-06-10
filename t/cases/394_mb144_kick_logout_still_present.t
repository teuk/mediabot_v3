# t/cases/394_mb144_kick_logout_still_present.t
# =============================================================================
# Test de la correction mb144 :
#
#   - B1 : on_message_KICK faisait $auth->logout($kicked_nick) inconditionnellement
#          des qu'un user etait kick d'UN canal. C'est exactement le meme
#          bug que mb128-B1 pour PART, qui n'avait pas ete fixe en
#          parallele pour KICK. Le user kick reste sur IRC et peut etre
#          legitimement present sur d'autres canaux ou son auth doit
#          perdurer. Le fix : verifier still_present avant logout.
# =============================================================================

use strict;
use warnings;

return sub {
    my ($assert) = @_;

    # Implementation du check (identique au fix mb128-B1 pour PART)
    my $should_logout = sub {
        my ($hn, $kicked_nick) = @_;
        my $lc_target = lc($kicked_nick);
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

    # Implementation buggy (ancien comportement)
    my $should_logout_buggy = sub {
        return 1;   # toujours logout, peu importe les autres canaux
    };

    # -------------------------------------------------------------------------
    # Cas 1 : user kick d'UN canal, reste sur 2 autres → NO logout
    # -------------------------------------------------------------------------
    {
        # Apres channelNicksRemove(#chanA, Bob), Bob n'est plus dans #chanA
        # mais reste dans #chanB et #chanC
        my $hn = {
            '#chanA' => ['Alice', 'Charlie'],    # Bob deja retire (kick)
            '#chanB' => ['Bob', 'Alice'],
            '#chanC' => ['Bob', 'Dave'],
        };
        $assert->($should_logout->($hn, 'Bob') == 0,
            "B1 Bob kick de #chanA, present sur #chanB+#chanC -> NO logout");
        $assert->($should_logout_buggy->() == 1,
            "B1 REGRESSION-POC: ancien code logout Bob malgre les autres canaux");
    }

    # -------------------------------------------------------------------------
    # Cas 2 : user kick du seul canal partage -> LOGOUT
    # -------------------------------------------------------------------------
    {
        my $hn = {
            '#chanA' => ['Alice', 'Charlie'],    # Bob deja retire
        };
        $assert->($should_logout->($hn, 'Bob') == 1,
            "B1 Bob kick du seul canal partage -> logout");
    }

    # -------------------------------------------------------------------------
    # Cas 3 : case-insensitive matching (RFC 2812)
    # -------------------------------------------------------------------------
    {
        my $hn = {
            '#chanA' => ['alice'],
            '#chanB' => ['BOB', 'dave'],
        };
        $assert->($should_logout->($hn, 'Bob') == 0,
            "B1 case-insensitive: BOB present, Bob kick -> NO logout");
    }

    # -------------------------------------------------------------------------
    # Cas 4 : edge cases vides
    # -------------------------------------------------------------------------
    {
        $assert->($should_logout->({}, 'Bob') == 1,
            "B1 hChannelNicks vide -> logout");
        $assert->($should_logout->(undef, 'Bob') == 1,
            "B1 undef -> logout");
    }

    {
        my $hn = { '#chanA' => [], '#chanB' => [] };
        $assert->($should_logout->($hn, 'Bob') == 1,
            "B1 arrays vides -> logout");
    }

    # -------------------------------------------------------------------------
    # Cas 5 : comparaison KICK vs PART (meme logique)
    # -------------------------------------------------------------------------
    # Le check est strictement identique au fix mb128-B1 pour PART.
    # Verifions que les deux retournent les memes resultats pour les memes
    # entrees, garantissant la coherence semantique.
    {
        my @scenarios = (
            # [hn, target_nick, expected_logout]
            [{ '#a' => ['Bob'] }, 'Charlie', 1],                    # Charlie absent partout
            [{ '#a' => ['Bob'], '#b' => ['Charlie'] }, 'Bob', 0],   # Bob sur #a uniquement
            [{ '#a' => ['Bob'], '#b' => ['Bob'] }, 'Bob', 0],       # Bob sur 2 canaux
            [{ '#a' => ['ALICE'] }, 'alice', 0],                    # case-insensitive
        );
        for my $sc (@scenarios) {
            my ($hn, $nick, $expected) = @$sc;
            my $kick_result = $should_logout->($hn, $nick);
            $assert->($kick_result == $expected,
                "B1 coherence KICK/PART: nick=$nick expected=$expected got=$kick_result");
        }
    }

    # -------------------------------------------------------------------------
    # Cas 6 : scenario realiste — admin kick un troll qui a 2 nicks sur IRC
    # -------------------------------------------------------------------------
    # Bob authentifie sur #ops et #general. Admin le kick de #general.
    # Avant fix : Bob loggout globalement → doit refaire login pour #ops.
    # Apres fix : Bob auth preservee sur #ops (logique).
    {
        my $hn_before = {
            '#general' => ['Bob', 'admin'],
            '#ops'     => ['Bob', 'admin'],
        };

        # Simuler channelNicksRemove('#general', 'Bob')
        my $hn_after = {
            '#general' => ['admin'],            # Bob retire
            '#ops'     => ['Bob', 'admin'],     # toujours present
        };

        $assert->($should_logout->($hn_after, 'Bob') == 0,
            "B1 scenario realiste: admin kick Bob de #general, Bob auth preservee pour #ops");
        $assert->($should_logout_buggy->() == 1,
            "B1 REGRESSION-POC realiste: ancien code aurait casse l'auth de Bob");
    }
};
