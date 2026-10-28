use strict;
use warnings;
use Test::More;
use Mediabot::SafeCalc qw(evaluate_expression);
use Mediabot::DBCommands;
use Mediabot::Context;
use MockBot;

my @warnings;
local $SIG{__WARN__} = sub { push @warnings, @_ };

# Test each distinct numerical boundary once, without multiplying it by
# command facades. Compare residuals so public six-digit formatting cannot
# conceal a one-unit rounding error in a large integer.
for my $case (
    ['round(0)', 0],
    ['round(3.4)', 3], ['round(-3.4)', -3],
    ['round(3.6)', 4], ['round(-3.6)', -4],
    ['round(0.5)', 1], ['round(-0.5)', -1],
    ['round(0.49999999999999994)', 0],
    ['round(-0.49999999999999994)', 0],
    ['round(1.4999999999999998)', 1],
    ['round(-1.4999999999999998)', -1],
    ['round(4503599627370497)-4503599627370497', 0],
    ['round(-4503599627370497)+4503599627370497', 0],
    ['round(4503599627370495.5)-4503599627370496', 0],
    ['round(-4503599627370495.5)+4503599627370496', 0],
    ['round(1e300)/1e300', 1], ['round(-1e300)/1e300', -1],
) {
    is(evaluate_expression($case->[0]), $case->[1], $case->[0]);
}

{
    no warnings qw(redefine once);
    local *Mediabot::DBCommands::logBot = sub { 1 };
    for my $channel ('#test', undef) {
        my $bot = MockBot->new;
        my $expr = 'round(4503599627370497)-4503599627370497';
        my $ctx = Mediabot::Context->new(bot => $bot, nick => 'alice',
            channel => $channel, command => 'calc', args => [$expr]);
        Mediabot::DBCommands::mbCalc_ctx($ctx);
        is_deeply([$bot->replies], [{type => defined($channel) ? 'privmsg' : 'notice',
            to => $channel // 'alice', text => "$expr = 0"}],
            'actual calc command sends the corrected residual to its destination');
        is_deeply($bot->{_calc_history}{alice}, ["$expr = 0"],
            'history stores the corrected calculation');
    }
}
is_deeply(\@warnings, [], 'boundary arithmetic and command delivery emit no warnings');
done_testing;
