use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
BEGIN { unshift @INC, "$Bin/../.." }
use Mediabot::Spark::Replay qw(replay_events);

{
    package MB798::Config;
    sub new { bless { values => $_[1] }, $_[0] }
    sub get { $_[0]{values}{$_[1]} }
}
my $conf = MB798::Config->new({
    'conversation.CHANNEL_BOTS' => 'room:Coin',
    'conversation.CHANNEL_COMMANDS' => 'room:!bang',
});
my %base = (conf => $conf, channel => '#room', bot_nick => 'Mediabot');
my $empty = replay_events(%base, events => [{at => 0, type => 'probe'}]);
is($empty->{probes}[0]{momentum_reason}, 'audience_too_small',
    'empty room does not produce momentum');
is($empty->{probes}[0]{revival}, 'skip',
    'empty room does not produce a revival');

my @chat = (
    {at => 0, type => 'line', nick => 'Alice', message => 'un café'},
    {at => 1, type => 'line', nick => 'Bob', message => 'bonjour'},
    {at => 2, type => 'line', nick => 'Alice', message => 'il arrive'},
    {at => 3, type => 'line', nick => 'Bob', message => 'merci'},
);
my @excluded = (
    {at => 4, type => 'line', nick => 'Coin', message => 'duck appears'},
    {at => 5, type => 'line', nick => 'Alice', message => 'Coin: !bang'},
    {at => 6, type => 'line', nick => 'Bob', message => '!bang now'},
);
my @probes = (
    {at => 50, type => 'probe'},
    {at => 70, type => 'probe'},
    {at => 90, type => 'probe'},
);
my $clean = replay_events(%base, events => [@chat, @probes]);
my $actual = replay_events(%base, events => [@chat, @excluded, @probes]);
is_deeply($actual->{probes}, $clean->{probes},
    'excluded bot, direct address and command cannot change Spark decisions');
is_deeply($actual->{excluded}, {
    declared_bot => 1, bot_address => 1, bot_command => 1,
}, 'each central exclusion is counted without preserving message text');
is($actual->{probes}[0]{momentum}, 'action_candidate',
    'genuine small conversation yields one bounded momentum candidate');
is($actual->{repeated_momentum}, 0,
    'probes in the same conversation window never repeat momentum');
is_deeply([sort keys %$actual], [sort qw(decisions excluded probes repeated_momentum)],
    'output retains only decision metadata and counters');

my $solo = replay_events(%base, events => [
    {at => 0, type => 'line', nick => 'Alice', message => 'hello'},
    {at => 1, type => 'line', nick => 'Alice', message => 'anyone here'},
    {at => 55, type => 'probe'},
]);
is($solo->{probes}[0]{momentum_reason}, 'audience_too_small',
    'solo room cannot gain momentum from repeated lines');
my $quiet = replay_events(%base, events => [
    {at => 0, type => 'line', nick => 'Alice', message => 'hello'},
    {at => 2400, type => 'probe'},
]);
is($quiet->{probes}[0]{revival}, 'dryrun_candidate',
    'a single voice may qualify for the long-silence revival lane');
is($quiet->{probes}[0]{revival_regime}, 'solo',
    'quiet-room revival reports the audience regime');
my @crowd;
for my $round (1 .. 2) {
    for my $nick (qw(Alice Bob Carol Dave Erin Frank)) {
        push @crowd, {at => scalar(@crowd), type => 'line',
            nick => $nick, message => "round $round"};
    }
}
my $busy = replay_events(%base, events => [@crowd, {at => 41, type => 'probe'}]);
is($busy->{probes}[0]{momentum}, 'action_candidate',
    'busy room qualifies after a short breathing pause');
is($busy->{probes}[0]{momentum_regime}, 'crowded',
    'busy-room probe reports the crowded regime');
my $pressure = replay_events(%base, events => [
    @chat,
    {at => 10, type => 'line', nick => 'NewsRelay', message => 'news', from_bot => 1},
    {at => 50, type => 'probe'},
]);
is($pressure->{probes}[0]{momentum_reason}, 'action_probe_wait',
    'nonexcluded automation still delays momentum until its probe window ends');

for my $invalid (
    [{at => 1, type => 'probe'}, {at => 0, type => 'probe'}],
    [{at => 0, type => 'line', nick => 'Alice', message => "bad\nline"}],
    [{at => 604_801, type => 'probe'}],
) {
    my $ok = eval { replay_events(%base, events => $invalid); 1 };
    ok(!$ok, 'unbounded, reversed or unsafe replay input is refused');
}
done_testing;
