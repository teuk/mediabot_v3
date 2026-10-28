use strict;
use warnings;
use utf8;
use Test::More;
use Storable qw(dclone);
our (@DRAWS, @LIMITS, $DRAWING);
BEGIN {
    *CORE::GLOBAL::rand = sub {
        return CORE::rand($_[0] // 1) unless $DRAWING;
        die "unplanned random draw\n" unless @DRAWS;
        push @LIMITS, $_[0];
        return shift(@DRAWS) * ($_[0] // 1);
    };
}
use Mediabot::Mediabot;
use Mediabot::Context;
use Mediabot::PluginContext;
use Mediabot::Plugin::InvocationV3;
require './plugins/playful-v3/lib/Playful.pm';

binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
my (@warnings, @wire, @audit, @expected_history);
local $SIG{__WARN__} = sub { push @warnings, @_ };
no warnings qw(redefine once);
local *Mediabot::UserCommands::botPrivmsg = sub { push @wire, ['public', $_[1], $_[2]]; 1 };
local *Mediabot::UserCommands::botNotice = sub { die "unexpected native notice\n" };
local *Mediabot::UserCommands::logBot = sub { push @audit, [@_[2..$#_]]; 1 };
my $bot = Mediabot->new({});
my $authority = Mediabot::PluginContext->new(plugin => 'playful-v3',
    requested => [qw(irc.reply irc.notice)], granted => [qw(irc.reply irc.notice)]);
my $plugin = Mediabot::Plugin::Playful->new(context => $authority);
sub run_1368 {
    my ($kind, $args, $draws, $channel) = @_;
    $channel //= '#test'; @wire = (); @DRAWS = @$draws; @LIMITS = ();
    my ($input, $call);
    if ($kind eq 'native') {
        $input = Mediabot::Context->new(bot => $bot, nick => 'Alice',
            channel => $channel, command => 'roll', args => [@$args]);
        $call = sub { $bot->command_registry->handler_for('roll','public')->($input) };
    } else {
        $input = Mediabot::Plugin::InvocationV3->new(nick => 'Alice', channel => $channel,
            command => 'roll', args => $args, source => 'public', is_private => 0,
            authority => $authority, activation => 'on', config => {},
            reply_sink => sub { push @wire, ['public', $channel, $_[0]]; 1 },
            notice_sink => sub { die "unexpected plugin notice\n" });
        $call = sub { $plugin->command_roll($authority, $input) };
    }
    { local $DRAWING = 1; $call->() }
    my $history = $kind eq 'native' ? $bot->{_roll_history} : $plugin->{roll_history};
    return dclone({wire => \@wire, limits => \@LIMITS, remaining => \@DRAWS,
        args => $input->args, last => exists($history->{$channel}) ? $history->{$channel}[-1] : undef});
}
my @cases = (
    [[], [.5], [6], 'Alice rolled 1d6: 4'],
    [['+2'], [0], [6], 'Alice rolled 1d6: 1 +2 = 3'],
    [['-3'], [.5], [6], 'Alice rolled 1d6: 4 -3 = 1'],
    [['adv'], [.1,.8], [6,6], "Alice rolled 1d6 (adv): [5, \x1e1\x0f]  → 5"],
    [['disadvantage','+2'], [.1,.8], [6,6], "Alice rolled 1d6 (dis): [1, \x1e5\x0f] +2 = 3  → 3"],
    [['+2','adv'], [.1,.8], [6,6], "Alice rolled 1d6 (adv): [5, \x1e1\x0f] +2 = 7  → 7"],
    [['1d20','+2','adv'], [.1,.8], [20,20], "Alice rolled 1d20 (adv): [17, \x1e3\x0f] +2 = 19  → 19"],
    [['20','dis','-2'], [.1,.8], [20,20], "Alice rolled 1d20 (dis): [3, \x1e17\x0f] -2 = 1  → 1"],
    [['2d6','+3'], [0,.5], [6,6], 'Alice rolled 2d6: [1, 4] +3 = 8'],
    [['+999'], [0], [6], 'Alice rolled 1d6: 1 +100 = 101'],
    [['1d6','-999'], [0], [6], 'Alice rolled 1d6: 1 -100 = -99'],
);
for my $case (@cases) {
    my ($args, $draws, $limits, $text) = @$case;
    my $expected = {wire => [['public','#test',$text]], limits => $limits,
        remaining => [], args => $args, last => $text};
    is_deeply([map { run_1368($_, $args, $draws) } qw(native plugin)],
        [$expected, $expected], 'native and v3 preserve modifiers, draws, input and history: roll ' . join(' ', @$args));
    push @expected_history, $text;
}
my @last_five = @expected_history[-5..-1];
is_deeply([$bot->{_roll_history}{'#test'}, $plugin->{roll_history}{'#test'}],
    [\@last_five, \@last_five], 'both paths retain only their latest five actual rolls');
is_deeply(\@audit, [map { ['#test','roll',$_] } ((('1d6') x 6), '1d20', '1d20', '2d6', '1d6', '1d6')],
    'native rolls retain exactly one audit entry with their actual dice label');
my $history_text = 'Last rolls: ' . join('  |  ', reverse @last_five);
my $before = dclone([$bot->{_roll_history}, $plugin->{roll_history}, \@audit]);
for my $case (['#test', $history_text], ['#other', 'Alice: no roll history on #other.']) {
    my ($channel, $text) = @$case;
    my $results = [map { run_1368($_, ['history'], [], $channel) } qw(native plugin)];
    my $expected = [[['public',$channel,$text]], [], []];
    is_deeply([map { [$_->{wire}, $_->{limits}, $_->{remaining}] } @$results],
        [$expected, $expected], 'history replies are channel scoped and consume no random draws');
}
is_deeply([$bot->{_roll_history}, $plugin->{roll_history}, \@audit], $before,
    'history queries consume no draws and do not record new rolls or audit entries');
is_deeply(\@warnings, [], 'default dice options emit no warnings');
done_testing;
