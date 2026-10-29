use strict;
use warnings;
BEGIN {
    our $now = 1_800_000_000;
    *CORE::GLOBAL::time = sub { $main::now };
}
use Test::More;
use Mediabot::IRC::CommandThrottle ();
use Mediabot::Helpers ();

{
    package MB1016::Conf;
    sub get { $_[0]{$_[1]} }
    package MB1016::Log;
    sub log { push @{$_[0]{lines}}, [@_[1,2]]; 1 }
    package MB1016::Metrics;
    sub inc { $_[0]{$_[1]}++; 1 }
    package MB1016::NoIO;
    our $AUTOLOAD;
    sub AUTOLOAD { die 'Unexpected database or IRC operation' }
    sub DESTROY {}
}
sub bot_1391 {
    return {
        conf => bless({
            'antiflood.NICKFLOOD_MAX_COMMANDS' => 1,
            'antiflood.NICKFLOOD_WINDOW' => 5,
            'antiflood.NICKFLOOD_STATE_TTL' => 120,
        }, 'MB1016::Conf'),
        logger => bless({lines => []}, 'MB1016::Log'),
        metrics => bless({}, 'MB1016::Metrics'),
        dbh => bless({}, 'MB1016::NoIO'), irc => bless({}, 'MB1016::NoIO'),
    };
}
sub mute_1391 {
    my ($bot, $nick) = @_;
    return [map {Mediabot::Helpers::checkNickFlood($bot, $nick, '#test')} 1..4];
}
sub mute_keys_1391 { return [sort keys %{$_[0]{_nick_mute} || {}}] }
my @notices;
no warnings qw(redefine once);
local *Mediabot::Helpers::botNotice = sub {push @notices, [@_[1..$#_]]; 1};
my $bot = bot_1391();
my $start = $main::now;
my @nicks = map {"Reader$_"} 1..12;
my @results = map {mute_1391($bot, $_)} @nicks;
is_deeply([\@results, scalar(keys %{$bot->{_nick_mute}}),
           [sort {$a <=> $b} values %{$bot->{_nick_mute}}],
           scalar @notices, $bot->{metrics}{mediabot_nickflood_blocks_total},
           $bot->{metrics}{mediabot_nickflood_mutes_total}],
    [[map {[0,1,1,1]} @nicks], 12, [($start + 300) x 12], 12, 36, 12],
    'native guard keeps its threshold, three strikes, five-minute sanctions and notification metrics');

$main::now = $start + 121;
my $allowed = Mediabot::IRC::CommandThrottle::checkNickFlood($bot, 'Observer', '#other');
is_deeply([$allowed, [sort keys %{$bot->{_nick_flood}}],
           mute_keys_1391($bot), $bot->{_nick_flood_last_cleanup}],
    [0, ['observer'], [sort map {lc $_} @nicks], $main::now],
    'history TTL cleanup retains every still-active mute even after its nick history is removed');

$main::now = $start + 299;
my $before = scalar @notices;
my $blocked = Mediabot::Helpers::checkNickFlood($bot, 'READER1', '#other');
is_deeply([$blocked, $bot->{_nick_mute}{reader1},
           $bot->{_nick_flood_last_cleanup}, scalar(@notices) - $before,
           exists($bot->{_nick_flood}{reader1}) ? 1 : 0],
    [1, $start + 300, $start + 121, 0, 0],
    'active mute fast path still blocks case variants across channels without notices or new history');

$main::now = $start + 300;
$allowed = Mediabot::Helpers::checkNickFlood($bot, 'NewReader', '#test');
is_deeply([$allowed, mute_keys_1391($bot), [sort keys %{$bot->{_nick_flood}}],
           scalar @notices, $bot->{metrics}{mediabot_nickflood_blocks_total},
           $bot->{metrics}{mediabot_nickflood_mutes_total}],
    [0, [], ['newreader'], 12, 36, 12],
    'an unrelated command purges expired mutes at their deadline without absent users returning');

{
    my $waves = bot_1391();
    $waves->{_chan_flood} = {'#other' => {silenced_until => $main::now + 900}};
    $waves->{_cmd_cooldown} = {'ai:#other' => $main::now};
    my $channel_deadline = $main::now + 900;
    my $command_stamp = $main::now;
    my (@actual, @expected);
    for my $wave (1..3) {
        mute_1391($waves, "Wave${wave}Nick$_") for 1..4;
        $main::now += 300;
        my $ok = Mediabot::Helpers::checkNickFlood($waves, "Observer$wave", '#test');
        push @actual, [$ok, mute_keys_1391($waves), $waves->{_chan_flood}, $waves->{_cmd_cooldown}];
        push @expected, [0, [], {'#other' => {silenced_until => $channel_deadline}},
            {'ai:#other' => $command_stamp}];
    }
    is_deeply(\@actual, \@expected,
        'successive real mute/expiry waves do not accumulate abandoned sanctions or alter other throttle state');
}
{
    my $mixed = bot_1391();
    my $base = $main::now;
    $mixed->{_nick_mute} = {old => $base-1, edge => $base, active => $base+300, later => $base+301};
    $mixed->{_nick_flood_last_cleanup} = $base - 120;
    my @snapshots;
    Mediabot::Helpers::checkNickFlood($mixed, 'Observer', '#test');
    push @snapshots, [mute_keys_1391($mixed), $mixed->{_nick_flood_last_cleanup}];
    $mixed->{_nick_mute}{between_sweeps} = $base + 118;
    $main::now = $base + 119;
    Mediabot::Helpers::checkNickFlood($mixed, 'Observer', '#test');
    push @snapshots, [mute_keys_1391($mixed), $mixed->{_nick_flood_last_cleanup}];
    $main::now++;
    Mediabot::Helpers::checkNickFlood($mixed, 'AnotherReader', '#test');
    push @snapshots, [mute_keys_1391($mixed), $mixed->{_nick_flood_last_cleanup}];
    is_deeply(\@snapshots, [
        [['active','later'], $base], [['active','between_sweeps','later'], $base],
        [['active','later'], $base+120]],
        'mixed active/expired state is swept only on the existing TTL cadence, including the exact boundary');
}
{
    my $current = bot_1391();
    my $base = $main::now;
    $current->{_nick_mute} = {reader => $base, absent => $base-1};
    $current->{_nick_flood_last_cleanup} = $base-1;
    my @warnings;
    my $result;
    {
        local $SIG{__WARN__} = sub {push @warnings, @_};
        $result = Mediabot::Helpers::checkNickFlood($current, 'READER', '#test');
    }
    is_deeply([$result, mute_keys_1391($current),
               $current->{_nick_flood_last_cleanup}, $current->{_nick_flood}{reader}{hits}, \@warnings],
        [0, ['absent'], $base-1, [$base], []],
        'returning nick still expires immediately between sweeps and starts ordinary history without warnings');
}
done_testing;
