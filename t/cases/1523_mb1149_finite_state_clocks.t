use strict;
use warnings;
use Test::More;
use Storable qw(dclone);
use Mediabot::AI::ConversationFloodGuard;
use Mediabot::Spark::State;

for my $class ('Mediabot::AI::ConversationFloodGuard', 'Mediabot::Spark::State') {
    my $spark = $class =~ /Spark/;
    for my $bad ('Inf', '+Inf', 'Infinity', '1e9999', 'NaN', -1, undef, []) {
        my $now = 1000;
        my $object = $class->new(clock => sub { $now });
        my $observe = sub { $spark ? $object->observe_human(channel => '#test', nick => 'alice')
                                  : $object->observe_public_line(channel => '#test') };
        my $query = sub { $spark ? $object->snapshot('#test')
                                : $object->current_decision(channel => '#test') };
        $observe->();
        my $before = dclone($object->{channel_state});
        $now = $bad;
        for my $call ($query, $observe) {
            my $ok = eval { $call->(); 1 };
            ok(!$ok, "$class rejects invalid clock");
            like($@, qr/clock must return a non-negative numeric value/, 'clock validation error');
            is_deeply($object->{channel_state}, $before, 'rejection preserves channel state');
        }
        $now = 1001;
        my $ok = eval { $observe->(); $query->(); 1 };
        ok($ok, 'finite clock recovers without poisoned deadlines') or diag($@);
        is($object->{channel_state}{'#test'}{last_seen}, 1001, 'finite timestamp recorded');
    }
    for my $valid (0, 0.5, '1e3') {
        my $object = $class->new(clock => sub { $valid });
        my $ok = eval { $spark ? $object->observe_human(channel => '#valid', nick => 'alice')
                              : $object->observe_public_line(channel => '#valid'); 1 };
        ok($ok, "$class accepts finite non-negative clock") or diag($@);
    }
}
done_testing;
