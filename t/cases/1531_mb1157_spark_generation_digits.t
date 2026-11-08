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
done_testing;
