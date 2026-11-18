package MB1335::Case1265;
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
# MB1348: IRC nickname letter case must not split the same user's history.
{
    require Mediabot::UserCommands;
    my $bot = MockBot->new;
    my $invoke = sub {
        my ($command, $nick, $channel, @args) = @_;
        $bot->reset_replies;
        my $ctx = Mediabot::Context->new(bot=>$bot, nick=>$nick,
            channel=>$channel, command=>$command, args=>\@args);
        if ($command eq 'calc') { Mediabot::DBCommands::mbCalc_ctx($ctx) }
        else { Mediabot::UserCommands::mbCalcLast_ctx($ctx) }
        return [map { [@{$_}{qw(type to text)}] } $bot->replies];
    };
    $invoke->('calc', 'Alice', '#first', '6*7');
    is_deeply($invoke->('calclast', 'aLICE', undef), [
        ['notice', 'aLICE', 'Last 1 calc(s) for aLICE:'],
        ['notice', 'aLICE', '  6*7 = 42'],
    ], 'changing nickname letter case retains calc history and the private reply spelling');
    $invoke->('calc', 'ALICE', '#second', '10+2');
    $invoke->('calc', 'aLiCe', undef, '7-3');
    $invoke->('calc', 'alice', '#first', 'sqrt(81)');
    is_deeply($invoke->('calclast', 'Alice', '#history'), [
        ['privmsg', '#history', 'Last 3 calc(s) for Alice:'],
        ['privmsg', '#history', '  sqrt(81) = 9'],
        ['privmsg', '#history', '  7-3 = 4'],
        ['privmsg', '#history', '  10+2 = 12'],
    ], 'mixed-case calculations share one newest-first history capped at three across reply contexts');
    is_deeply($invoke->('calclast', 'ALIce', undef, '2'), [
        ['notice', 'ALIce', 'Last 2 calc(s) for ALIce:'],
        ['notice', 'ALIce', '  sqrt(81) = 9'],
        ['notice', 'ALIce', '  7-3 = 4'],
    ], 'optional history count still applies after a case change');
    my @before = @{$bot->{_calc_history}{alice} // []};
    @logged = ();
    $invoke->('calc', 'aLICE', '#first', '1/0');
    is_deeply([$bot->{_calc_history}{alice}, scalar @logged], [\@before, 0],
        'a refused calculation under another casing neither changes history nor creates an audit');
    is_deeply($invoke->('calclast', 'Alice_', undef),
        [['notice', 'Alice_', 'No calc history yet.']],
        'a distinct nickname cannot read Alice history');
    $invoke->('calc', 'Alice_', '#first', '3*3');
    is_deeply([$bot->{_calc_history}{alice}, $bot->{_calc_history}{alice_},
        [sort keys %{$bot->{_calc_history}}]], [\@before, ['3*3 = 9'], ['alice', 'alice_']],
        'separate users retain separate histories and case variants create no extra cache keys');
    is_deeply($invoke->('calclast', 'ALICE', '#history', '4'),
        [['notice', 'ALICE', 'Syntax: calclast [1-3]']],
        'invalid history count is still refused privately');
    is_deeply($bot->{_calc_history}{alice}, \@before,
        'history reads and count refusals leave the shared history unchanged');
}
1;
