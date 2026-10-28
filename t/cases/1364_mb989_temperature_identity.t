use strict;
use warnings;
use utf8;
use Test::More;
use Mediabot::Convert;
use Mediabot::DBCommands;
use Mediabot::Context;
use MockBot;

binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
my (@warnings, @logged);
local $SIG{__WARN__} = sub { push @warnings, @_ };

# Canonical names and aliases must preserve the input, even when an offset
# round trip would cancel it. Keep one case for each distinct boundary.
for my $case (
    ['1e-30', 'k', 'kelvin', '1e-30 K = 1e-30 K'],
    ['-1e-30', 'fahrenheit', '°F', '-1e-30 °F = -1e-30 °F'],
    ['1e-10', 'kelvin', 'K', '1e-10 K = 1e-10 K'],
    ['1e-30', 'c', 'centigrade', '1e-30 °C = 1e-30 °C'],
    ['0', 'f', 'F', '0 °F = 0 °F'],
    ['1e308', 'kelvin', 'k', '1e+308 K = 1e+308 K'],
) {
    my ($value, $from, $to, $expected) = @$case;
    is_deeply([Mediabot::Convert::convert($value, $from, $to)], [1, $expected],
        "$value $from to $to preserves a same-unit temperature");
}

{
    no warnings qw(redefine once);
    local *Mediabot::DBCommands::logBot = sub { push @logged, [@_] };
    for my $channel ('#test', undef) {
        my $bot = MockBot->new; @logged = ();
        my $ctx = Mediabot::Context->new(bot => $bot, nick => 'alice',
            channel => $channel, command => 'convert',
            args => ['1e-30', 'k', 'to', 'kelvin']);
        Mediabot::DBCommands::mbConvert_ctx($ctx);
        is_deeply([$bot->replies], [{type => defined($channel) ? 'privmsg' : 'notice',
            to => $channel // 'alice', text => '1e-30 K = 1e-30 K'}],
            'the actual conversion handler delivers the preserved value');
        is(scalar @logged, 1, 'the successful conversion is logged once');
    }
}
is_deeply(\@warnings, [], 'same-unit temperatures produce no warnings');
done_testing;
