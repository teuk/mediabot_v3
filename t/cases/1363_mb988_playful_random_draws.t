use strict;
use warnings;
use utf8;
use Test::More;
binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
our (@DRAWS, @LIMITS);
BEGIN {
    # Fixed draws verify repeats and bounds without statistical thresholds or
    # reseeding the process. Plugin code is loaded below this override.
    *CORE::GLOBAL::rand = sub {
        return CORE::rand($_[0] // 1) unless @DRAWS;
        push @LIMITS, $_[0];
        return shift(@DRAWS) * ($_[0] // 1);
    };
}
use Mediabot::PluginContext;
use Mediabot::Plugin::InvocationV3;
require './plugins/playful-v3/lib/Playful.pm';

my $authority = Mediabot::PluginContext->new(plugin => 'playful-v3',
    requested => [qw(irc.reply irc.notice)], granted => [qw(irc.reply irc.notice)]);
my $plugin = Mediabot::Plugin::Playful->new(context => $authority);
my (@replies, @warnings);
local $SIG{__WARN__} = sub { push @warnings, @_ };
sub run_1363 {
    my ($command, $channel, $args, @draws) = @_;
    @replies = (); @DRAWS = @draws; @LIMITS = ();
    my $invocation = Mediabot::Plugin::InvocationV3->new(
        nick => 'Alice', channel => $channel, command => $command,
        args => $args, source => 'public', is_private => 0,
        authority => $authority, activation => 'on', config => {},
        reply_sink => sub { push @replies, $_[0]; 1 },
        notice_sink => sub { die "unexpected notice: $_[0]\n" });
    my $method = 'command_' . $command;
    $plugin->$method($authority, $invocation);
}

run_1363('flip', '#test', ['4'], .1, .1, .9, .9);
is_deeply(\@replies, ['Alice flipped 4 coins: HHTT  (2 H, 2 T)'],
    'consecutive coins can repeat on both sides instead of alternating');
is_deeply(\@LIMITS, [2,2,2,2], 'each coin obtains a separate bounded draw');
is_deeply(\@DRAWS, [], 'the source is consumed exactly once per coin');
run_1363('flip', '#test', ['stats']);
is_deeply(\@replies,
    ['Alice flip stats on #test: 2 Heads (50%)  2 Tails (50%)  — 4 total'],
    'statistics account for the actual sequence');
run_1363('flip', '#other', ['stats']);
is_deeply(\@replies, ['Alice: no flips yet on #other.'], 'statistics remain channel scoped');
run_1363('flip', '#test', ['99'], (.1) x 10);
is_deeply(\@replies, ['Alice flipped 10 coins: HHHHHHHHHH  (10 H, 0 T)'],
    'the ten-coin limit remains and does not force a balanced outcome');
is_deeply($plugin->{flip_stats}{'#test'}, {h => 12, t => 2}, 'counters accumulate repeated outcomes');

run_1363('roll', '#test', ['2d6'], 0, 0);
is_deeply(\@replies, ['Alice rolled 2d6: [1, 1] = 2'], 'consecutive dice can return the same face');
is_deeply(\@LIMITS, [6,6], 'dice keep their requested range');
run_1363('roll', '#test', ['1d20', '+2', 'adv'], 0, .999999);
like($replies[0], qr/rolled 1d20 \(adv\): \[20, .*1.*\].*→ 22\z/,
    'advantage keeps the larger draw and applies the modifier');
run_1363('roll', '#test', ['history']);
like($replies[0], qr/^Last rolls: .*adv.*\|.*\[1, 1\] = 2\z/, 'history records actual roll results');
run_1363('choose', '#test', ['tea:2', '|', 'coffee'], .999999);
is_deeply(\@replies, ['Alice: I choose... coffee! (1 of 3 options)'],
    'weighted choices still select from the existing expanded pool');
run_1363('choose', '#test', ['last']);
is_deeply(\@replies, ['Alice: last choice was: coffee'], 'the last choice remains available');

for my $size (1,2,6,20) {
    @DRAWS = (0, .999999); @LIMITS = ();
    is_deeply([map { $plugin->_rand_index($size) } 1..2], [0, $size-1],
        "range $size retains both endpoints with integer indices");
}
is_deeply(\@warnings, [], 'command draws emit no warnings');
done_testing;
