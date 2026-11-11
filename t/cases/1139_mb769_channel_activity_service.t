# MB769 — bounded detached channel-activity aggregates.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

return sub {
    my ($assert) = @_;
    require Mediabot::Plugin::ChannelActivityServiceV3;

    my @calls;
    my $service = Mediabot::Plugin::ChannelActivityServiceV3->new(
        gatherer => sub {
            my ($sql, $bind, $consumer, $scope) = @_;
            push @calls, { sql => $sql, bind => [ @$bind ], scope => $scope };
            if ($sql =~ /HOUR\(cl\.ts\)/) {
                $consumer->({ hour => 0, count => 2 });
                $consumer->({ hour => 0, count => 3 });
                $consumer->({ hour => 23, count => 4 });
            }
            else {
                $consumer->({ nick => 'Luna', count => 4 });
                $consumer->({ nick => 'luna', count => 6 });
                $consumer->({ nick => 'Neville', count => 7 });
            }
            return { live_ok => 1, archive_ok => 1 };
        },
    );

    my $comp = $service->compare(
        channel => '#GreatHall', left => 'Luna', right => 'Neville',
        period => '4w')->{comparison};
    $assert->is(ref($comp), 'Mediabot::Plugin::ActivityComparisonV3',
        'compare returns an opaque detached comparison');
    $assert->is($comp->left_count, 10,
        'case-folded live and archive aggregates are merged');
    $assert->is($comp->right_count, 7,
        'second comparison count is preserved');
    $assert->is($comp->period, '4w', 'validated period is retained');
    $assert->like($calls[0]{sql}, qr/INTERVAL 4 WEEK/,
        'period becomes only a validated fixed SQL interval');
    $assert->is(join('|', @{ $calls[0]{bind} }),
        '#GreatHall|luna|neville',
        'channel and nicknames stay prepared bind values');
    $assert->is($calls[0]{scope}, 'content',
        'activity reads use the bounded content archive scope');

    my $detached = $comp->as_hash;
    $detached->{left_count} = 999;
    $assert->is($comp->left_count, 10,
        'comparison snapshots cannot mutate the opaque value');

    my $heatmap = $service->heatmap(
        channel => '#GreatHall', nick => 'Luna')->{heatmap};
    $assert->is(ref($heatmap), 'Mediabot::Plugin::ActivityHeatmapV3',
        'heatmap returns an opaque detached value');
    $assert->is(scalar @{ $heatmap->hours }, 24,
        'heatmap always exposes exactly 24 hourly counters');
    $assert->is($heatmap->hours->[0], 5,
        'duplicate source buckets are merged');
    $assert->is($heatmap->hours->[23], 4,
        'late-hour bucket is preserved');
    $assert->is($heatmap->total, 9,
        'heatmap total is derived inside the immutable value');
    my $hours = $heatmap->hours;
    $hours->[0] = 999;
    $assert->is($heatmap->hours->[0], 5,
        'hour arrays are returned as detached copies');

    for my $bad (
        sub { $service->compare(channel => '#x', left => 'a', right => 'a') },
        sub { $service->compare(channel => '#x', left => 'a', right => 'b', period => '366d') },
        sub { $service->heatmap(channel => 'not-a-channel', nick => 'a') },
        sub { $service->heatmap(channel => '#x', nick => "bad nick") },
    ) {
        my $ok = eval { $bad->(); 1 };
        $assert->ok(!$ok && $@, 'invalid activity input fails closed');
    }

    # MB1204: malformed API periods must never widen a query to all history.
    my $scalar_period = '4w';
    for my $period ([], {}, \$scalar_period, sub { '4w' }) {
        my $before = scalar @calls;
        my $ok = eval {
            $service->compare(channel => '#x', left => 'a', right => 'b', period => $period);
            1;
        };
        $assert->ok(!$ok, 'mb1204: reference period is rejected');
        $assert->like($@ // '', qr/invalid period/, 'mb1204: period diagnostic is explicit');
        $assert->is(scalar @calls, $before, 'mb1204: invalid period never invokes the gatherer');
    }
    for my $period (undef, '', 'all', 'ALL') {
        my $result = $service->compare(channel => '#x', left => 'a', right => 'b', period => $period);
        $assert->is($result->{comparison}->period, 'all', 'mb1204: existing all-time defaults retained');
        $assert->unlike($calls[-1]{sql}, qr/INTERVAL/, 'mb1204: valid all-time request has no interval');
    }
    for my $pair (['365D', '365 DAY'], ['52W', '52 WEEK'],
                  ['24M', '24 MONTH'], ['10Y', '10 YEAR']) {
        my $result = $service->compare(channel => '#x', left => 'a', right => 'b', period => $pair->[0]);
        $assert->is($result->{comparison}->period, lc($pair->[0]), 'mb1204: period boundary remains accepted');
        $assert->like($calls[-1]{sql}, qr/INTERVAL \Q$pair->[1]\E/, 'mb1204: bounded interval remains exact');
    }

    my $unavailable = Mediabot::Plugin::ChannelActivityServiceV3->new(
        gatherer => sub { return { live_ok => 0 } },
    );
    my $ok = eval {
        $unavailable->heatmap(channel => '#x', nick => 'luna');
        1;
    };
    $assert->ok(!$ok && $@ =~ /data service unavailable/,
        'missing live authority fails closed without partial data');
};
