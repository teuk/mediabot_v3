use strict;
use warnings;
use utf8;
use Test::More;
use FindBin qw($Bin);

BEGIN {
    unshift @INC, "$Bin/../..";
    # The preview never invokes Helpers or Hailo storage. Keep this test
    # runnable without the optional live IRC/SQLite dependency tree.
    package Mediabot::Helpers;
    sub import { }
    $INC{'Mediabot/Helpers.pm'} = 1;
    package Hailo;
    sub import { }
    $INC{'Hailo.pm'} = 1;
}

use Mediabot::Hailo ();
use Mediabot::Hailo::Policy;

{
    package MB796::Conf;
    sub new { bless {}, $_[0] }
    sub get {
        my (undef, $key) = @_;
        return 'i/o:Coin' if $key eq 'conversation.CHANNEL_BOTS';
        return 'i/o:!bang' if $key eq 'conversation.CHANNEL_COMMANDS';
        return '#' if $key eq 'main.MAIN_PROG_CMD_CHAR';
        return undef;
    }
}
{
    package MB796::IRC;
    sub nick_folded { 'mediabotv3' }
}
my $draws = 0;
my $policy = Mediabot::Hailo::Policy->new(
    now_cb => sub { 100 }, rng_cb => sub { $draws++; 99 },
    key_reply_rate => 95,
);
my $bot = bless {
    conf => MB796::Conf->new,
    irc => bless({}, 'MB796::IRC'),
    hailo_policy => $policy,
    hailo_registry => bless({}, 'MB796::ForbiddenBrain'),
}, 'MB796::Bot';

no warnings 'redefine';
local *Mediabot::Hailo::hailo_channel_policy = sub {
    return { master => 1, learn => 1, respond => 1, chatter => 1 };
};
local *Mediabot::Hailo::is_hailo_excluded_nick = sub { 0 };

my %base = (
    channel => '#i/o', speaker => 'Te[u]K', mode => 'mention',
);
my $bot_command = Mediabot::Hailo::hailo_preview_turn($bot,
    %base, text => '!bang maintenant');
is($bot_command->{learn_reason}, 'bot_command',
    'real exclusion configuration blocks an external command before policy');
is($bot_command->{reply}, 0, 'excluded external command cannot reach reply');
my $address = Mediabot::Hailo::hailo_preview_turn($bot,
    %base, text => 'Coin: réponds au canard');
is($address->{learn_reason}, 'bot_address',
    'direct address to the configured external bot is also blocked');

my $ordinary = Mediabot::Hailo::hailo_preview_turn($bot,
    %base, text => 'bonjour tout le monde');
ok($ordinary->{ok} && $ordinary->{learn} && $ordinary->{reply},
    'ordinary line passes normalization and channel learn/reply gates');
ok($ordinary->{rate_pending}, 'real mention draw remains pending');
is($draws, 0, 'real policy random stream has not advanced');
is($policy->stats->{channels}, 0, 'rehearsal did not allocate live policy state');
ok(!exists($ordinary->{text}) && !exists($ordinary->{candidate}),
    'rehearsal result never contains sample text or an answer');

my $own_command = Mediabot::Hailo::hailo_preview_turn($bot,
    %base, text => '#help quoi de neuf');
is($own_command->{learn_reason}, 'command',
    'normalizer excludes Mediabot public commands from learning');
is($own_command->{reply_reason}, 'command',
    'normalizer excludes Mediabot public commands from replies');

done_testing;
