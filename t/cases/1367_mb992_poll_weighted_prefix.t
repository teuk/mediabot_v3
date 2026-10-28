use strict;
use warnings;
use utf8;
use Test::More;
use Storable qw(dclone);
BEGIN { *CORE::GLOBAL::time = sub () { 2000 } }
use Mediabot::Mediabot;
use Mediabot::Context;
use MockUser;

binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
{
    package MB992::Metrics;
    sub inc { $_[0]{$_[1]}++; 1 }
    sub set { $_[0]{$_[1]} = $_[2]; 1 }
    package MB992::Bot;
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
sub invoke_1367 {
    my ($bot, $command, $raw, $nick, $channel, $user) = @_;
    my $ctx = Mediabot::Context->new(bot => $bot, nick => $nick // 'Alice',
        channel => $channel // '#test', command => $command,
        args => defined($raw) ? [split / /, $raw, -1] : []);
    $ctx->{user} = $user // $master; $ctx->{_user_fetched} = 1;
    return $bot->command_registry->handler_for($command, 'public')->($ctx);
}
sub setup_1367 {
    my $bot = Mediabot->new({}); bless $bot, 'MB992::Bot';
    $bot->{wire} = []; $bot->{metrics} = bless {}, 'MB992::Metrics';
    @audit = ();
    return $bot;
}
sub poll_view_1367 {
    my ($bot) = @_;
    my $p = $bot->{_polls}{'#test'};
    return [@$p{qw(question options weights weighted started deadline active)}];
}
for my $raw ('60 weighted Thé ? | Oui:3 | Non:1',
             'weighted 60 Thé ? | Oui:3 | Non:1') {
    my $bot = setup_1367();
    invoke_1367($bot, 'poll', $raw);
    is_deeply(poll_view_1367($bot), ['Thé ?', ['Oui','Non'], [3,1], 1, 2000, 2060, 1],
        'documented and legacy prefix orders enable weights and the requested deadline');
    is_deeply([$bot->{wire}, $bot->{metrics}{mediabot_poll_created_total}, \@audit],
        [[['public','#test','Poll: "Thé ?"  [1] Oui  [2] Non  -- vote with !vote <n>']],
         1, [['#test','poll','Thé ?']]], 'creation announces, counts and audits the parsed question once');
}
for my $case (
    ['weighted Thé ? | Oui:3 | Non', 'Thé ?', ['Oui','Non'], [3,1], 1, 2300],
    ['60 Thé ? | Oui:3 | Non', 'Thé ?', ['Oui:3','Non'], [1,1], 0, 2060],
    ['2026? | 0 | 1', '2026?', ['0','1'], [1,1], 0, 2300],
    ['1 weighted Q | A:2 | B', 'Q', ['A','B'], [2,1], 1, 2010],
    ['weighted 9999 Q | A:2 | B', 'Q', ['A','B'], [2,1], 1, 5600],
    ['weighted 60 weighted vote? | A:2 | B', 'weighted vote?', ['A','B'], [2,1], 1, 2060],
) {
    my ($raw, $question, $options, $weights, $weighted, $deadline) = @$case;
    my $bot = setup_1367(); invoke_1367($bot, 'poll', $raw);
    is_deeply(poll_view_1367($bot), [$question, $options, $weights, $weighted, 2000, $deadline, 1],
        'optional prefixes retain defaults, timeout clamps and literal question/option text');
}
{
    my $bot = setup_1367();
    invoke_1367($bot, 'poll', '60 weighted Lunch? | Pizza:3 | Sushi:1');
    invoke_1367($bot, 'poll', 'Other | one | two', 'Alice', '#other');
    my $other = dclone($bot->{_polls}{'#other'});
    invoke_1367($bot, 'vote', '1', 'Alice');
    invoke_1367($bot, 'vote', '2', 'Bob');
    invoke_1367($bot, 'vote', '2', 'Charlie');
    like($bot->{wire}[-1][2], qr/Pizza \(x3\): 1=3 \(60%\).*Sushi \(x1\): 2=2 \(40%\)/,
        'real vote handler applies weights in its public live tally');
    $bot->{wire} = [];
    invoke_1367($bot, 'pollresult');
    like($bot->{wire}[0][2], qr/Winner: Pizza \(60% weighted\)/,
        'real result handler selects the weighted winner despite fewer voters');
    $bot->{wire} = [];
    invoke_1367($bot, 'pollstop');
    like(join('\n', map { $_->[2] } @{$bot->{wire}}), qr/Winner: Pizza/,
        'closing the poll selects the same weighted winner');
    is_deeply($bot->{_polls}{'#other'}, $other, 'voting, results and closing preserve the other channel');
    my $before = dclone([$bot->{_polls}, {%{$bot->{metrics}}}, \@audit]);
    $bot->{wire} = [];
    invoke_1367($bot, 'poll', '60 weighted Q | A:3 | ');
    is_deeply([$bot->{_polls}, {%{$bot->{metrics}}}, \@audit, $bot->{wire}],
        [@$before, [['notice','Alice','Syntax: poll <question> | option1 | option2 ...']]],
        'new prefix order still refuses empty fields without changing votes, metrics or audit');
    $bot->{wire} = [];
    invoke_1367($bot, 'poll', '60 weighted Q | A:3 | B:1', 'Alice', '#test',
        MockUser->new(level => 'User', auth => 1));
    is_deeply([$bot->{_polls}, {%{$bot->{metrics}}}, \@audit, $bot->{wire}],
        [@$before, [['notice','Alice','Your level does not allow you to use this command.']]],
        'Master authorization remains before parsing or mutation');
}
is_deeply(\@warnings, [], 'prefix parsing and weighted voting emit no warnings');
done_testing;
