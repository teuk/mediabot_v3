use strict;
use warnings;
use utf8;
use Test::More;
use Storable qw(dclone);
BEGIN { *CORE::GLOBAL::time = sub () { 1_900_000_000 } }
use Mediabot::Mediabot;
use Mediabot::Context;
binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';

my (@wire, @warnings);
local $Storable::canonical = 1;
no warnings qw(redefine once);
local *Mediabot::UserCommands::botPrivmsg = sub { push @wire, ['public', $_[1], $_[2]]; 1 };
local *Mediabot::UserCommands::botNotice = sub { push @wire, ['notice', $_[1], $_[2]]; 1 };
local $SIG{__WARN__} = sub { push @warnings, @_ };
my $bot = Mediabot->new({});
my $now = 1_900_000_000;
sub vote_1408 { +{ nick => 'Alice', ts => $now - $_[0], delta => $_[1] } }
sub graph_1408 {
    my ($entries, $args, $channel) = @_;
    $bot->{_karma_log} = { '#test' => $entries,
        '#other' => [vote_1408(0, '-1')] };
    @wire = ();
    my $ctx = Mediabot::Context->new(bot => $bot, nick => 'Alice',
        channel => $channel // '#test', command => 'karmgraph', args => $args // ['ALICE']);
    $ctx->{_user_fetched} = 1;
    my $before = dclone($bot->{_karma_log});
    $bot->command_registry->handler_for('karmgraph', 'public')->($ctx);
    die 'read-only graph mutated the vote history' unless Storable::freeze($before) eq Storable::freeze($bot->{_karma_log});
    return [@wire];
}
sub public_1408 { ['public', '#test', "karma graph alice (7d) $_[0]  net: $_[1]"] }
sub empty_1408 { ['public', '#test', 'alice: no karma activity in the last 7 days.'] }

is_deeply(graph_1408([vote_1408(0, '+1'), vote_1408(1, '-1')]),
    [public_1408('·······', '+0')], 'opposite votes today remain real activity with a zero net');
is_deeply(graph_1408([vote_1408(86400, '+1'), vote_1408(-3600, '+1')]),
    [public_1408('·····█·', '+1')], 'a future vote less than one day away cannot become today activity');
is_deeply(graph_1408([vote_1408(86400, '+1'), vote_1408(-172800, '+1')]),
    [public_1408('·····█·', '+1')], 'a future vote omitted from the graph cannot inflate its net');
is_deeply(graph_1408([vote_1408(-1, '+1')]), [empty_1408()],
    'even one second in the future is outside the observed seven-day interval');
is_deeply(graph_1408([vote_1408(604799, '+1'), vote_1408(604800, '-1')]),
    [public_1408('█······', '+1')], 'the last second inside seven days counts and the exact lower boundary does not');
is_deeply(graph_1408([vote_1408(604800, '+1'), vote_1408(604801, '-1')]),
    [empty_1408()], 'history at or before the excluded boundary stays empty');
is_deeply(graph_1408([vote_1408(86399, '+1'), vote_1408(86400, '-1')]),
    [public_1408('·····▼█', '+0')], 'adjacent rolling-day buckets preserve signs and sum to the displayed net');
is_deeply(graph_1408([vote_1408(0, '+1')], []),
    [public_1408('······█', '+1')], 'the default caller target and a vote at the observation instant still work');
is_deeply(graph_1408([{nick => 'Bob', ts => $now, delta => '+1'}]), [empty_1408()],
    'another nick or channel never contributes to the selected graph');
is_deeply(graph_1408([vote_1408(0, '+1'), vote_1408(1, undef),
    {nick => 'Alice', delta => '-1'}]),
    [public_1408('······█', '+1')], 'incomplete cached records cannot change the graph or its net');
is_deeply(graph_1408([vote_1408(0, '+1')], ['graph', 'Alice']),
    [public_1408('······█', '+1')], 'the historical optional graph keyword remains accepted');
is_deeply(graph_1408([vote_1408(0, '+1')], [], 'Alice'),
    [['notice', 'Alice', '!karmgraph requires a channel context. Use it in a channel.']],
    'the public-channel requirement remains unchanged');
is_deeply(\@warnings, [], 'all graph paths are warning-free and leave their source histories untouched');
done_testing;
