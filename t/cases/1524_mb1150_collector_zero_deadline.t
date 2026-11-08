use strict;
use warnings;
use Test::More;
use Mediabot::Spark::Portal;
use Mediabot::Spark::Mosaic;

for my $class ('Mediabot::Spark::Portal', 'Mediabot::Spark::Mosaic') {
    for my $start (0, 0.25, 1000) {
        for my $timeout (5, 30, 120) {
            my $now = $start;
            my $collector = $class->new(clock => sub { $now }, closing_timeout_seconds => $timeout);
            my %event = (channel => '#test', generation => 1, target => 2);
            is($collector->snapshot('#test')->{closing_timed_out}, 0, 'inactive collector does not time out');
            is($collector->begin(%event)->{action}, 'begin', "$class begins at $start");
            for my $nick ('alice', 'bob') {
                is($collector->collect(%event, nick => $nick, message => '+magic')->{action},
                   'collect', 'public API accepts contribution');
            }
            is($collector->snapshot('#test')->{closing_timed_out}, 0, 'collecting is not closing');
            is($collector->mark_closing(%event)->{action}, 'close', 'closing starts');
            for my $case ([0,0], [$timeout - 0.25,0], [$timeout,1], [$timeout + 1,1]) {
                $now = $start + $case->[0];
                my $snapshot = $collector->snapshot('#test');
                is($snapshot->{closing_timed_out}, $case->[1], "$class start=$start timeout=$timeout elapsed=$case->[0]");
                is($snapshot->{count}, 2, 'timeout inspection preserves contributions');
            }
            $collector->forget_channel('#test');
            is($collector->snapshot('#test')->{closing_timed_out}, 0, 'forgotten event does not time out');
        }
    }
}
done_testing;
