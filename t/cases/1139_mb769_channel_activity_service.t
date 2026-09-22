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
