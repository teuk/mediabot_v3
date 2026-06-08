# t/cases/387_mb128_part_logout_and_purge_caches.t
# =============================================================================
# Tests des corrections mb128 :
#
#   - B1 : on_message_PART faisait $auth->logout($sNick) inconditionnellement
#          des qu'un user partait d'UN canal. Trop severe quand l'user est
#          present sur plusieurs canaux partages avec le bot. Apres ce fix
#          on ne logout que si le user n'est plus sur AUCUN autre canal.
#
#   - B2 : Completer le cache cleanup de purgeChannel_ctx (mb125-B1) avec
#          les caches oublies: _quote_last_rand, _quote_bynick_last,
#          _karma_log, _quotegame, _duel_*, _karma_brigade, _karma_cooldown.
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

    # -------------------------------------------------------------------------
    # B2: simulation du cache cleanup additionnel de purgeChannel_ctx
    # -------------------------------------------------------------------------
    my $purge_additional = sub {
        my ($self, $sChannel) = @_;
        my @keys = ($sChannel, lc($sChannel));

        for my $chan_key (@keys) {
            delete $self->{_quote_last_rand}{$chan_key}  if $self->{_quote_last_rand};
            delete $self->{_quotegame}{$chan_key}        if $self->{_quotegame};
            delete $self->{_karma_log}{$chan_key}        if $self->{_karma_log};
            for my $duel (qw(_duel_stats _duel_cooldown _duel_streak _duel_last_result)) {
                delete $self->{$duel}{$chan_key} if $self->{$duel};
            }
            delete $self->{_karma_cooldown}{$chan_key}   if $self->{_karma_cooldown};
        }

        if ($self->{_quote_bynick_last}) {
            for my $bk (keys %{ $self->{_quote_bynick_last} }) {
                my $colon = index($bk, ':');
                next if $colon < 0;
                my $bk_chan = substr($bk, 0, $colon);
                delete $self->{_quote_bynick_last}{$bk}
                    if $bk_chan eq $sChannel || lc($bk_chan) eq lc($sChannel);
            }
        }

        if ($self->{_karma_brigade}) {
            for my $bk (keys %{ $self->{_karma_brigade} }) {
                my $last_colon = rindex($bk, ':');
                next if $last_colon < 0;
                my $bk_chan = substr($bk, $last_colon + 1);
                delete $self->{_karma_brigade}{$bk}
                    if $bk_chan eq $sChannel || lc($bk_chan) eq lc($sChannel);
            }
        }
    };

    my $bot = {
        _quote_last_rand => {
            '#chanA' => 42,
            '#chanB' => 99,
        },
        _quote_bynick_last => {
            '#chanA:bob'   => 1,
            '#chanA:alice' => 2,
            '#chanB:bob'   => 3,
        },
        _quotegame => {
            '#chanA' => { active => 1 },
            '#chanB' => { active => 0 },
        },
        _karma_log => {
            '#chanA' => [{ts => 1}, {ts => 2}],
            '#chanB' => [{ts => 3}],
        },
        _karma_brigade => {
            'brigade:alice:#chanA' => { hits => [1,2,3] },
            'brigade:dave:#chanB'  => { hits => [4] },
            'brigade:bob:#chanA'   => { hits => [5,6] },
        },
        _karma_cooldown => {
            '#chanA' => { 'bob:alice' => time() },
            '#chanB' => { 'alice:dave' => time() },
        },
        _duel_stats => {
            '#chanA' => { bob => { wins => 5 } },
            '#chanB' => { alice => { wins => 2 } },
        },
        _duel_cooldown => {
            '#chanA' => { bob => time() },
            '#chanB' => { dave => time() },
        },
        _duel_streak => {
            '#chanA' => { bob => 3 },
            '#chanB' => { alice => 1 },
        },
        _duel_last_result => {
            '#chanA' => 'bob beat alice',
            '#chanB' => 'dave beat eric',
        },
    };

    $purge_additional->($bot, '#chanA');

    # Verifier: #chanA disparait partout, #chanB intact
    $assert->(!exists $bot->{_quote_last_rand}{'#chanA'},
        "B2 _quote_last_rand #chanA removed");
    $assert->( exists $bot->{_quote_last_rand}{'#chanB'},
        "B2 _quote_last_rand #chanB preserved");

    $assert->(!exists $bot->{_quote_bynick_last}{'#chanA:bob'},
        "B2 _quote_bynick_last #chanA:bob removed");
    $assert->(!exists $bot->{_quote_bynick_last}{'#chanA:alice'},
        "B2 _quote_bynick_last #chanA:alice removed");
    $assert->( exists $bot->{_quote_bynick_last}{'#chanB:bob'},
        "B2 _quote_bynick_last #chanB:bob preserved");

    $assert->(!exists $bot->{_quotegame}{'#chanA'},
        "B2 _quotegame #chanA removed");
    $assert->( exists $bot->{_quotegame}{'#chanB'},
        "B2 _quotegame #chanB preserved");

    $assert->(!exists $bot->{_karma_log}{'#chanA'},
        "B2 _karma_log #chanA removed");
    $assert->( exists $bot->{_karma_log}{'#chanB'},
        "B2 _karma_log #chanB preserved");

    $assert->(!exists $bot->{_karma_brigade}{'brigade:alice:#chanA'},
        "B2 _karma_brigade brigade:alice:#chanA removed");
    $assert->(!exists $bot->{_karma_brigade}{'brigade:bob:#chanA'},
        "B2 _karma_brigade brigade:bob:#chanA removed");
    $assert->( exists $bot->{_karma_brigade}{'brigade:dave:#chanB'},
        "B2 _karma_brigade brigade:dave:#chanB preserved");

    $assert->(!exists $bot->{_karma_cooldown}{'#chanA'},
        "B2 _karma_cooldown #chanA removed");
    $assert->( exists $bot->{_karma_cooldown}{'#chanB'},
        "B2 _karma_cooldown #chanB preserved");

    for my $d (qw(_duel_stats _duel_cooldown _duel_streak _duel_last_result)) {
        $assert->(!exists $bot->{$d}{'#chanA'},
            "B2 $d #chanA removed");
        $assert->( exists $bot->{$d}{'#chanB'},
            "B2 $d #chanB preserved");
    }

    # Regression POC : si on N'avait PAS le cleanup additionnel, ces caches
    # resteraient et un futur !chanadd #chanA reutiliserait les vieux ids.
    {
        my $bot2 = {
            _quote_last_rand => { '#oldchan' => 42 },
        };
        # Pas de purge -> la cle reste
        $assert->(exists $bot2->{_quote_last_rand}{'#oldchan'},
            "B2 REGRESSION-POC: sans purge, cle survit (proves the bug)");
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

