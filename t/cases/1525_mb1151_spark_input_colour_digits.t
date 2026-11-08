use strict;
use warnings;
use utf8;
use Test::More;
use Mediabot::Spark::Observer;
use Mediabot::Spark::Portal;
use Mediabot::Spark::Mosaic;

my @cases = (
    ["\x0304,12magic", 'magic'],
    ["\x03magic", 'magic'],
    ["\x030412magic", '12magic'],
);
for my $digits ('١٢', '１２', '१२', '𝟙𝟚') {
    push @cases, ["\x03${digits}magic", "${digits}magic"],
                 ["\x0304${digits}magic", "${digits}magic"],
                 ["\x0304,12${digits}magic", "${digits}magic"];
}
for my $case (@cases) {
    my ($input, $expected) = @$case;
    my $observer = Mediabot::Spark::Observer->new(clock => sub { 1000 });
    $observer->observe_public_line(channel => '#test', nick => 'alice', message => $input);
    is_deeply($observer->context_lines('#test'), ["alice: $expected"], 'observer preserves visible digits');
    for my $class ('Mediabot::Spark::Portal', 'Mediabot::Spark::Mosaic') {
        my $collector = $class->new(clock => sub { 1000 });
        my %event = (channel => '#test', generation => 1, target => 2);
        $collector->begin(%event);
        my $message = $class =~ /Mosaic/ ? "+$input" : $input;
        is($collector->collect(%event, nick => 'alice', message => $message)->{action}, 'collect', "$class accepts contribution");
        is_deeply($collector->contributions(%event), [$expected], "$class preserves visible digits");
    }
}
# A comma followed by non-ASCII digits is visible text, not a background colour.
my $observer = Mediabot::Spark::Observer->new(clock => sub { 1000 });
$observer->observe_public_line(channel => '#test', nick => 'alice', message => "\x0304,١٢magic");
is_deeply($observer->context_lines('#test'), ['alice: ,١٢magic'], 'non-ASCII background suffix remains literal');
my $portal = Mediabot::Spark::Portal->new(clock => sub { 1000 });
$portal->begin(channel => '#test', generation => 1);
$portal->collect(channel => '#test', generation => 1, nick => 'alice', message => "\x0304,١٢magic");
is_deeply($portal->contributions(channel => '#test', generation => 1), [',١٢magic'], 'Portal retains literal comma and digits');
my $mosaic = Mediabot::Spark::Mosaic->new(clock => sub { 1000 });
$mosaic->begin(channel => '#test', generation => 1, target => 2);
is($mosaic->collect(channel => '#test', generation => 1, nick => 'alice', message => "+\x0304,١٢magic")->{reason}, 'invalid_word', 'Mosaic validates the actual visible comma instead of silently deleting it');


# MB1163: consolidated from 1524_mb1150_collector_zero_deadline.t
{
package MB1163::Case1524;
use strict;
use warnings;
use Test::More;
use Mediabot::Spark::Portal;
use Mediabot::Spark::Mosaic;

for my $class ('Mediabot::Spark::Portal', 'Mediabot::Spark::Mosaic') {
    for my $timing ([0,5], [0,30], [0,120], [0.25,30], [1000,30]) {
        my ($start, $timeout) = @$timing;
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

# MB1163: consolidated from 1531_mb1157_spark_generation_digits.t
{
package MB1163::Case1531;
use strict;
use warnings;
use utf8;
use Test::More;
use Storable qw(dclone);
use Mediabot::Spark::State;
use Mediabot::Spark::Portal;
use Mediabot::Spark::Mosaic;
for my $bad ('1١', '1１', '1𝟙', '01', "1\n", undef, []) {
    my $state = Mediabot::Spark::State->new(clock => sub {1000});
    my $generation = $state->begin_event(channel=>'#test', kind=>'portal');
    is($generation, 1, 'fixture starts at first generation');
    my @warnings;
    my $current;
    { local $SIG{__WARN__} = sub {push @warnings, @_};
      $current = $state->generation_is_current('#test', $bad); }
    ok(!$current, 'malformed generation does not match active event');
    is_deeply(\@warnings, [], 'state rejects without numeric warnings');
    ok($state->generation_is_current('#test', $generation), 'real generation remains current');
    for my $class ('Mediabot::Spark::Portal', 'Mediabot::Spark::Mosaic') {
        for my $method ('begin', 'collect', 'mark_closing') {
            my $collector = $class->new(clock => sub {1000});
            my %event = (channel=>'#test', generation=>1, target=>2);
            $collector->begin(%event);
            $collector->collect(%event, nick=>$_, message=>'+magic') for ('alice','bob');
            my $before = dclone($collector->{channels});
            my @warnings;
            my $out;
            { local $SIG{__WARN__} = sub {push @warnings, @_};
              $out = $collector->$method(%event, generation=>$bad, nick=>'carol', message=>'+stars'); }
            is($out->{reason}, 'invalid_generation', "$class $method rejects malformed identity");
            is_deeply($collector->{channels}, $before, 'active contributions and phase remain intact');
            is_deeply(\@warnings, [], 'collector validates before numeric conversion');
            is($collector->mark_closing(%event)->{action}, 'close', 'valid generation can still close');
        }
    }
}


}

done_testing;
