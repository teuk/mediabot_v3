use strict;
use warnings;
use utf8;
use Test::More;
use Mediabot::AI::ConversationEmission qw(evaluate_emission);
my %base = (enabled=>1, runtime_active=>1, irc_connected=>1, channel_joined=>1,
            channel=>'#test', text=>'Hello there');
for my $bad ('1١', '1１', '1𝟙', '12٢', '١', '0', '01', '-1', '1.0', "1\n", '1234567890123456', undef, []) {
    for my $side ('request_generation', 'current_generation') {
        my @warnings;
        my $result;
        { local $SIG{__WARN__} = sub {push @warnings, @_};
          $result = evaluate_emission(%base, request_generation=>1, current_generation=>1, $side=>$bad); }
        is($result->{action}, 'no_emit', 'malformed generation cannot authorize emission');
        is($result->{reason}, 'stale_generation', 'generation gate rejects invalid identity');
        is_deeply(\@warnings, [], 'validation precedes numeric conversion');
    }
}
for my $generation (1, 12, 999999999999999) {
    my $result = evaluate_emission(%base, request_generation=>$generation, current_generation=>$generation);
    is($result->{action}, 'emit', 'matching valid ASCII generation authorizes emission');
    is($result->{request_generation}, $generation, 'identity retained');
    is(evaluate_emission(%base, request_generation=>$generation, current_generation=>$generation-1)->{action},
       'no_emit', 'different generation remains rejected');
}
done_testing;
