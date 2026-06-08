# t/cases/390_mb140_karma_brigade_distinct_voters.t
# =============================================================================
# Test de la correction mb140 :
#
#   - B1 : Le brigade detection comptait les HITS bruts (timestamps) au lieu
#          des NICKS DISTINCTS, malgre le commentaire explicite "5 different
#          nicks voting for same target in 30s". Resultat :
#            * Un seul user qui spam-vote 6 fois en 30s declenchait le
#              message "Karma brigade detected" (alors que le cooldown
#              anti-spam bloque deja le spam d'un meme nick)
#            * Le compteur de blocks etait gonfle artificiellement
#
#          Fix : passer de { hits => [t0,t1,t2,...], warned => 0 } a
#          { nicks => { 'lc_nick' => last_ts }, warned => 0 }.
# =============================================================================

use strict;
use warnings;

my $case = sub {
    my ($assert) = @_;

    # Implementation buggy : compte les hits bruts
    my $brigade_buggy = sub {
        my ($state, $nick, $target, $channel, $now) = @_;
        my $key = "brigade:$target:$channel";
        my $b = $state->{$key} //= { hits => [], warned => 0 };
        push @{ $b->{hits} }, $now;
        @{ $b->{hits} } = grep { ($now - $_) < 30 } @{ $b->{hits} };
        return scalar @{ $b->{hits} } > 5 ? 1 : 0;
    };

    # Implementation fixee (mb140-B1) : compte les nicks distincts
    my $brigade_fixed = sub {
        my ($state, $nick, $target, $channel, $now) = @_;
        my $key = "brigade:$target:$channel";
        my $b = $state->{$key} //= { nicks => {}, warned => 0 };
        $b->{nicks}{lc($nick)} = $now;
        for my $k (keys %{ $b->{nicks} }) {
            delete $b->{nicks}{$k} if ($now - $b->{nicks}{$k}) >= 30;
        }
        return scalar(keys %{ $b->{nicks} }) > 5 ? 1 : 0;
    };

    # -------------------------------------------------------------------------
    # Cas 1 (le bug) : un seul user spam-vote 6 fois
    # -------------------------------------------------------------------------
    {
        my $now = 1000000;
        my $st_buggy = {};
        my @triggered_buggy;
        for my $i (1..6) {
            push @triggered_buggy,
                $brigade_buggy->($st_buggy, 'spammer', 'victim', '#chan', $now + $i);
        }
        $assert->($triggered_buggy[5] == 1,
            "B1 REGRESSION-POC: ancien code declenche 'brigade' apres 6 votes du MEME user (faux positif)");

        my $st_fixed = {};
        my @triggered_fixed;
        for my $i (1..6) {
            push @triggered_fixed,
                $brigade_fixed->($st_fixed, 'spammer', 'victim', '#chan', $now + $i);
        }
        $assert->($triggered_fixed[5] == 0,
            "B1 FIX: nouveau code ne declenche PAS 'brigade' pour spam d'un meme nick");
    }

    # -------------------------------------------------------------------------
    # Cas 2 : 6 users distincts → BRIGADE LEGITIME
    # -------------------------------------------------------------------------
    {
        my $now = 1000000;
        my $st = {};
        my @triggered;
        for my $i (1..6) {
            push @triggered,
                $brigade_fixed->($st, "user$i", 'victim', '#chan', $now + $i);
        }
        # 1-5 : pas encore brigade (5 nicks = limite)
        $assert->($triggered[0] == 0, "B1 vote 1/6 (user1) : pas de brigade");
        $assert->($triggered[4] == 0, "B1 vote 5/6 (user5) : limite atteinte mais pas depassee");
        $assert->($triggered[5] == 1, "B1 vote 6/6 (user6) : 6 distincts > 5, BRIGADE !");
    }

    # -------------------------------------------------------------------------
    # Cas 3 : memes 5 users votent N fois chacun → PAS de brigade
    # -------------------------------------------------------------------------
    {
        my $now = 1000000;
        my $st = {};
        my $any_trigger = 0;
        for my $round (1..4) {
            for my $i (1..5) {
                $any_trigger ||=
                    $brigade_fixed->($st, "user$i", 'victim', '#chan',
                        $now + ($round * 10) + $i);
            }
        }
        $assert->(!$any_trigger,
            "B1 5 users distincts × 4 rounds = 20 hits mais 5 nicks → PAS brigade");
    }

    # -------------------------------------------------------------------------
    # Cas 4 : window de 30s — vieux entries expirent
    # -------------------------------------------------------------------------
    {
        my $now = 1000000;
        my $st = {};
        # 5 users votent a t=0
        for my $i (1..5) {
            $brigade_fixed->($st, "user$i", 'victim', '#chan', $now + $i);
        }
        # 100s plus tard, 1 nouveau user vote
        my $triggered = $brigade_fixed->($st, 'user6', 'victim', '#chan', $now + 1000);
        $assert->(!$triggered,
            "B1 vieux votes (>30s) expirent, nouveau vote isole != brigade");
        # Verifier que les anciens nicks ont ete purges
        my $b = $st->{"brigade:victim:#chan"};
        $assert->(scalar(keys %{ $b->{nicks} }) == 1,
            "B1 apres 1000s, 1 seul nick reste dans la window (user6)");
    }

    # -------------------------------------------------------------------------
    # Cas 5 : case-insensitive (Bob vs bob = meme voter)
    # -------------------------------------------------------------------------
    {
        my $now = 1000000;
        my $st = {};
        for my $form (qw(Bob bob BOB Bob bob)) {
            $brigade_fixed->($st, $form, 'victim', '#chan', $now);
            $now += 1;
        }
        my $b = $st->{"brigade:victim:#chan"};
        $assert->(scalar(keys %{ $b->{nicks} }) == 1,
            "B1 5 votes avec casses differentes du meme nick = 1 voter distinct");
    }

    # -------------------------------------------------------------------------
    # Cas 6 : migration ancien format -> nouveau format
    # -------------------------------------------------------------------------
    {
        my $brigade_with_migration = sub {
            my ($state, $nick, $target, $channel, $now) = @_;
            my $key = "brigade:$target:$channel";
            my $b = $state->{$key} //= { nicks => {}, warned => 0 };
            # Migration ancien format
            if (ref($b->{hits}) eq 'ARRAY' && !$b->{nicks}) {
                $b->{nicks} = {};
                delete $b->{hits};
            }
            $b->{nicks}{lc($nick)} = $now;
            for my $k (keys %{ $b->{nicks} }) {
                delete $b->{nicks}{$k} if ($now - $b->{nicks}{$k}) >= 30;
            }
            return scalar(keys %{ $b->{nicks} }) > 5 ? 1 : 0;
        };

        # State avec ancien format
        my $st = {
            'brigade:victim:#chan' => {
                hits => [100, 101, 102],   # ancien format
                warned => 1,
            },
        };

        $brigade_with_migration->($st, 'newuser', 'victim', '#chan', 200);

        my $b = $st->{"brigade:victim:#chan"};
        $assert->(!exists $b->{hits}, "B1 migration: ancien champ 'hits' supprime");
        $assert->(exists $b->{nicks}, "B1 migration: nouveau champ 'nicks' present");
        $assert->(scalar(keys %{ $b->{nicks} }) == 1, "B1 migration: 1 entree (le nouveau vote)");
        $assert->(exists $b->{nicks}{'newuser'}, "B1 migration: le bon nick");
    }
};

# ---------------------------------------------------------------------------
# Direct runner for standalone execution:
#   perl t/cases/390_mb140_karma_brigade_distinct_voters.t
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

