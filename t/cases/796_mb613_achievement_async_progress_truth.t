# t/cases/796_mb613_achievement_async_progress_truth.t
# =============================================================================
# mb613 — les valeurs calculees dans le worker forké doivent revenir au parent,
# et le worker doit honorer les seuils EFFECTIFS de [achievements].
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Temp qw(tempdir);

my $DIR = tempdir(CLEANUP => 1);

{
    package Conf796;
    sub new { bless { kv => $_[1] || {} }, $_[0] }
    sub get { $_[0]{kv}{ $_[1] } }
}
{
    package Log796;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, [ $_[1], $_[2] ]; 1 }
}

return sub {
    my ($assert) = @_;

    require Mediabot::Achievements;

    my $log = Log796->new;
    my $A = Mediabot::Achievements->new(
        path   => "$DIR/a.json",
        logger => $log,
        bot    => {
            conf => Conf796->new({
                'achievements.LEGEND'   => '222222',
                'achievements.POLYPHONY'=> '12',
            }),
        },
    );

    # [1] threshold snapshot: child keeps the configured values although its
    # runtime bot object no longer carries the conf object.
    my $W = bless {
        bot => { dbh => 'isolated' },
        _worker_thresholds => {
            legend    => $A->threshold('legend'),
            polyphony => $A->threshold('polyphony'),
        },
        _worker_progress => {},
    }, 'Mediabot::Achievements::Worker';

    $assert->is($W->threshold('legend'), 222222,
        'mb613-796: worker honours configured legend threshold');
    $assert->is($W->threshold('polyphony'), 12,
        'mb613-796: worker honours configured polyphony threshold');

    # [2] worker set_progress is an intent, not a child-only persistent state.
    $assert->is($W->set_progress('msg_count', 'Teuk', '#Chan', 1200), 1200,
        'mb613-796: worker captures msg_count');
    $assert->is($W->set_progress('msg_count', 'Teuk', '#Chan', 900), 1200,
        'mb613-796: worker keeps monotonic highest value in a job');
    $assert->is($W->{_worker_progress}{msg_count}, 1200,
        'mb613-796: worker exposes bounded progress result');

    # [3] parent consumes a successful worker result and persists the values.
    $A->{_pending_checks} = {
        "teuk\0#chan" => {
            nick => 'Teuk', channel => '#Chan', attempts => 0,
        },
    };
    $A->{_pending_order} = [ "teuk\0#chan" ];
    $A->{_worker_inflight} = {
        token => 77, key => "teuk\0#chan", started_at => time(),
    };

    my $ok = $A->_finish_async_check(77, {
        ok       => 1,
        checks   => [ 'msg_count', 'polyphony' ],
        unlocks  => [],
        timings  => {},
        progress => {
            msg_count       => 4321,
            channels_active => 7,
            evil            => 999999,
        },
    });
    $assert->ok($ok, 'mb613-796: parent accepts successful worker result');
    $assert->is($A->progress('msg_count', 'teuk', '#chan'), 4321,
        'mb613-796: msg_count crossed child/parent boundary');
    $assert->is($A->progress('channels_active', 'teuk', '#chan'), 7,
        'mb613-796: channels_active crossed child/parent boundary');
    $assert->is($A->progress('evil', 'teuk', '#chan'), 0,
        'mb613-796: unknown worker progress kind is ignored');
    $assert->is($A->pending_check_count, 0,
        'mb613-796: successful result still acknowledges queue entry');

    # [4] source guard: polyphony records the already-calculated count and
    # spawn result carries progress back to the parent.
    my $src = do {
        open my $fh, '<:encoding(UTF-8)', 'Mediabot/Achievements.pm' or die $!;
        local $/; <$fh>;
    };
    $assert->like($src,
        qr/set_progress\('channels_active',\s*\$nick,\s*\$channel,\s*\$nchan\)/,
        'mb613-796: check_msg records known polyphony count');
    $assert->like($src,
        qr/progress\s*=>\s*\$child->\{_worker_progress\}/,
        'mb613-796: child result transports progress');
    $assert->like($src,
        qr/my %worker_thresholds = map \{.*?\$self->threshold\(\$_\).*?\} keys %ACH/s,
        'mb613-796: effective thresholds are snapshotted before reduced worker bot');

    # [5] default human descriptions must agree with the mb611 defaults.
    my $defs = $A->list_definitions;
    my %needle = (
        legend          => '150 000',
        polyglot        => '7 500',
        karma_legend    => '+250',
        gift_giver      => '250',
        trivia_champion => '300',
        trivia_sniper   => '2 seconds',
        duel_master     => '150',
        underdog        => '8 in a row',
        matchmaker      => '25',
        quote_detective => '20',
        quote_master    => '150',
        polyphony       => '8 channels',
    );
    my $aligned = 0;
    for my $id (sort keys %needle) {
        my $desc = $defs->{$id}{desc} // '';
        $aligned++ if index($desc, $needle{$id}) >= 0;
    }
    $assert->is($aligned, scalar(keys %needle),
        'mb613-796: rebalanced default descriptions match their thresholds');

    # [6] stale mb608 copy must actually be gone.
    $assert->ok(!-e 't/cases/790_mb608_ai_summary_language.t',
        'mb613-796: stale pre-refactor mb608 test is removed');
};
