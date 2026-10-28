use strict;
use warnings;
use utf8;
use Test::More;
use Storable qw(dclone);
use Mediabot::Mediabot;
use Mediabot::Context;
use MockUser;

binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
{
    package MB991::Metrics;
    sub inc { $_[0]{$_[1]}++; 1 }
    package MB991::Bot;
    our @ISA = ('Mediabot');
    sub botNotice { push @{$_[0]{wire}}, ['notice', $_[1], $_[2]]; 1 }
}
my (@warnings, @audit);
local $SIG{__WARN__} = sub { push @warnings, @_ };
no warnings qw(redefine once);
local *Mediabot::UserCommands::botNotice = sub { push @{$_[0]{wire}}, ['notice', $_[1], $_[2]]; 1 };
local *Mediabot::UserCommands::botPrivmsg = sub { push @{$_[0]{wire}}, ['public', $_[1], $_[2]]; 1 };
local *Mediabot::UserCommands::logBot = sub { push @audit, [@_[2..$#_]]; 1 };
my $master = MockUser->new(level => 'Master', auth => 1);
sub invoke_1366 {
    my ($bot, $command, $channel, $args, $user) = @_;
    my $ctx = Mediabot::Context->new(bot => $bot, nick => 'Alice',
        channel => $channel, command => $command, args => $args);
    $ctx->{user} = $user // $master; $ctx->{_user_fetched} = 1;
    return $bot->command_registry->handler_for($command, 'public')->($ctx);
}
sub setup_1366 {
    my $bot = Mediabot->new({}); bless $bot, 'MB991::Bot';
    $bot->{wire} = []; $bot->{metrics} = bless {}, 'MB991::Metrics';
    invoke_1366($bot, 'poll', '#test', ['Original | Yes | No']);
    invoke_1366($bot, 'vote', '#test', [1]);
    invoke_1366($bot, 'poll', '#other', ['Other | one | two']);
    invoke_1366($bot, 'vote', '#other', [2]);
    $bot->{wire} = []; @audit = ();
    return $bot;
}
sub state_1366 { dclone([$_[0]{_polls}, {%{$_[0]{metrics}}}, \@audit]) }
my $syntax = [['notice', 'Alice', 'Syntax: poll <question> | option1 | option2 ...']];
for my $raw (' | A | B', 'Question | A | | B', 'Question | A | B | ',
             'Question | A | B|', 'weighted 60 Question | A:2 | ') {
    my $bot = setup_1366(); my $before = state_1366($bot);
    invoke_1366($bot, 'poll', '#test', [$raw]);
    is_deeply(state_1366($bot), $before, 'empty field preserves existing ballots, other channel, metrics and audit');
    is_deeply($bot->{wire}, $syntax, 'malformed poll produces only a private syntax notice');
}
{
    my $bot = setup_1366(); delete $bot->{_polls};
    my $before = state_1366($bot);
    invoke_1366($bot, 'poll', '#test', ['Question | A | ']);
    is_deeply(state_1366($bot), $before, 'empty option cannot create a poll when none exists');
    is_deeply($bot->{wire}, $syntax, 'empty initial poll is refused privately');
}
for my $case (['0|0|1', '0', ['0','1'], [1,1], 0],
              ['weighted 60 Thé ? | Oui:2 | Non:1', 'Thé ?', ['Oui','Non'], [2,1], 1]) {
    my ($raw, $question, $options, $weights, $weighted) = @$case;
    my $bot = setup_1366();
    invoke_1366($bot, 'poll', '#test', [$raw]);
    my $poll = $bot->{_polls}{'#test'};
    is_deeply([@$poll{qw(question options weights weighted votes active)}],
        [$question, $options, $weights, $weighted, {}, 1],
        'valid zero labels and weighted Unicode polls retain their existing representation');
    is_deeply([$bot->{metrics}{mediabot_poll_created_total}, scalar(@audit), scalar(@{$bot->{wire}}), $bot->{wire}[0][0]],
        [3,1,1,'public'], 'valid creation still counts, logs and announces once');
}
{
    my $bot = setup_1366(); my $before = state_1366($bot);
    invoke_1366($bot, 'poll', '#test', ['New | Yes | No'], MockUser->new(level => 'User', auth => 1));
    is_deeply(state_1366($bot), $before, 'Master gate remains before mutation');
    is_deeply($bot->{wire}, [['notice','Alice','Your level does not allow you to use this command.']],
        'insufficient privilege keeps the established private denial');
}
is_deeply(\@warnings, [], 'poll validation emits no warnings');
done_testing;
