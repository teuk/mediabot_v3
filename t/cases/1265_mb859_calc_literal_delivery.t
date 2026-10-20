use strict;
use warnings;
use utf8;
use lib '.', 't/lib';
use Test::More;
use MockBot;
use Mediabot::Context;
use Mediabot::DBCommands;

my @logged;
no warnings qw(redefine once);
local *Mediabot::DBCommands::logBot = sub { push @logged, [@_] };
use warnings;
sub context {
    my ($bot, $channel, $expr) = @_;
    return Mediabot::Context->new(bot => $bot, nick => 'alice', channel => $channel,
        command => 'calc', message => 'local arithmetic fixture', args => [$expr]);
}
for my $expr ("\x{661}+1", "2e\x{662}", "1.\x{ff12}+1") {
    for my $channel ('#test', undef) {
        my $bot = MockBot->new;
        Mediabot::DBCommands::mbCalc_ctx(context($bot, $channel, '6*7'));
        my @before = @{$bot->{_calc_history}{alice}};
        $bot->reset_replies; @logged = ();
        my (@warnings, $ok, $error);
        {
            local $SIG{__WARN__} = sub { push @warnings, @_ };
            $ok = eval { Mediabot::DBCommands::mbCalc_ctx(context($bot, $channel, $expr)); 1 };
            $error = $@;
        }
        ok($ok && !$error, 'unsupported digits produce a normal command refusal');
        my @replies = $bot->replies;
        is(scalar @replies, 1, 'unsupported arithmetic produces one response');
        is($replies[0]{type}, 'notice', 'unsupported arithmetic is refused privately');
        is($replies[0]{to}, 'alice', 'refusal reaches only its caller');
        is($replies[0]{text}, 'Invalid characters in expression.', 'refusal gives the existing bounded syntax error');
        is_deeply($bot->{_calc_history}{alice}, \@before, 'refused expression does not poison calculation history');
        is(scalar @logged, 0, 'refused expression creates no successful calculation audit event');
        is_deeply(\@warnings, [], 'refused expression leaks no Perl warning');
    }
}
for my $case (['2.5e+2', '250'], ['0xFF+1', '256'], ['2**-2', '0.25']) {
    my ($expr, $expected) = @$case;
    for my $channel ('#test', undef) {
        my $bot = MockBot->new; @logged = ();
        ok(eval { Mediabot::DBCommands::mbCalc_ctx(context($bot, $channel, $expr)); 1 }, 'supported arithmetic completes');
        my @replies = $bot->replies;
        is(scalar @replies, 1, 'supported arithmetic produces one response');
        is($replies[0]{type}, defined($channel) ? 'privmsg' : 'notice', 'success preserves Context routing');
        is($replies[0]{to}, $channel // 'alice', 'success uses the intended destination');
        is($replies[0]{text}, "$expr = $expected", 'success preserves the typed expression and result formatting');
        is_deeply($bot->{_calc_history}{alice}, ["$expr = $expected"], 'successful history records the unchanged expression');
        is(scalar @logged, 1, 'supported calculation is audited once');
    }
}
done_testing;
