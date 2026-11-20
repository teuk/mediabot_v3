use strict;
use warnings;
use utf8;
use Test::More;
use Storable qw(dclone);
our $NOW;
BEGIN { *CORE::GLOBAL::time = sub () { $NOW // 2000 } }
use Mediabot::Mediabot;
use Mediabot::Context;
use MockUser;

binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
{
    package MB1010::Metrics;
    sub inc { $_[0]{$_[1]}++; 1 }
    sub set { $_[0]{$_[1]} = $_[2]; 1 }
}
my (@wire, @audit);
no warnings qw(redefine once);
local *Mediabot::UserCommands::botNotice = sub { push @wire, ['notice', $_[1], $_[2]]; 1 };
local *Mediabot::UserCommands::botPrivmsg = sub { push @wire, ['public', $_[1], $_[2]]; 1 };
local *Mediabot::UserCommands::logBot = sub { push @audit, [@_[2..$#_]]; 1 };
my $master = MockUser->new(level => 'Master', auth => 1);
sub invoke_1385 {
    my ($bot, $command, $args, $nick, $channel) = @_;
    my $ctx = Mediabot::Context->new(bot => $bot, nick => $nick // 'Alice',
        channel => $channel // '#test', command => $command, args => [@{$args // []}]);
    $ctx->{user} = $master; $ctx->{_user_fetched} = 1;
    my (@warnings, $ok, $error);
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $ok = eval { $bot->command_registry->handler_for($command, 'public')->($ctx); 1 };
        $error = $@;
    }
    return dclone([$ok ? '' : $error, \@warnings, $ctx->args]);
}
sub setup_1385 {
    my ($weighted) = @_;
    my $bot = Mediabot->new({});
    $bot->{metrics} = bless {}, 'MB1010::Metrics';
    $NOW = 2000;
    invoke_1385($bot, 'poll', [split / /, ($weighted ? 'weighted ' : '') . '60 Thé ? | Oui:3 | Non:1']);
    invoke_1385($bot, 'poll', ['Elsewhere', '|', 'A', '|', 'B'], 'Alice', '#other');
    @wire = (); @audit = ();
    return $bot;
}
sub state_1385 {
    my ($bot) = @_;
    return dclone([$bot->{_polls}, {%{$bot->{metrics}}}, \@audit]);
}
my @invalid = ("1٢", "2１", '١', '１', "1\n", '1e0', '1.0', '-1', '0', '3');
for my $weighted (0, 1) {
    for my $replacement (0, 1) {
        my (@actual, @expected);
        for my $token (@invalid) {
            my $bot = setup_1385($weighted);
            invoke_1385($bot, 'vote', ['2']) if $replacement;
            @wire = ();
            my $before = state_1385($bot);
            my $call = invoke_1385($bot, 'vote', [$token]);
            push @actual, [$call, state_1385($bot), [@wire]];
            push @expected, [['', [], [$token]], $before,
                [['notice', 'Alice', 'Vote: use !vote <number> (1 to 2)']]];
        }
        is_deeply(\@actual, \@expected,
            ($weighted ? 'weighted' : 'ordinary') . ' poll: malformed numbers neither cast nor replace a ballot, warn, count or audit');
    }
}
{
    my $bot = setup_1385(1);
    my $other = dclone($bot->{_polls}{'#other'});
    my $first = invoke_1385($bot, 'vote', ['01']);
    my $second = invoke_1385($bot, 'vote', ['0002']);
    is_deeply([$first, $second, $bot->{_polls}{'#test'}{votes},
               $bot->{_polls}{'#other'}, $bot->{metrics}{mediabot_poll_votes_total}, \@audit],
        [['', [], ['01']], ['', [], ['0002']], {alice => 1}, $other, 2,
         [['#test','vote','Oui'], ['#test','vote','Non']]],
        'whole ASCII numbers, leading zeroes, changing a ballot and channel isolation keep their established behavior');
    invoke_1385($bot, 'vote', ['1'], 'Bob');
    invoke_1385($bot, 'vote', ["2١"], 'Bob');
    @wire = ();
    invoke_1385($bot, 'pollresult');
    like(join('\n', map { $_->[2] } @wire), qr/Winner: Oui \(75% weighted\)/,
        'a malformed replacement cannot change the weighted result');
    @wire = ();
    invoke_1385($bot, 'unvote', [], 'Bob');
    is_deeply([$bot->{_polls}{'#test'}{votes}, $wire[0]],
        [{alice => 1}, ['public','#test','Bob cancelled their vote (1 vote(s) remaining).']],
        'a refused replacement leaves the original ballot available for normal withdrawal');
}
{
    my $bot = setup_1385(0);
    invoke_1385($bot, 'vote', ['2']);
    @wire = ();
    my $before = state_1385($bot);
    $before->[0]{'#test'}{active} = 0;
    $NOW = 2061;
    my $call = invoke_1385($bot, 'vote', ["1٢"]);
    is_deeply([$call, state_1385($bot), [@wire]],
        [['', [], ["1٢"]], $before,
         [['public','#test','Poll expired. Use !pollresult to see results.']]],
        'the existing lazy-expiry rule still closes a due poll before input handling and preserves its ballots');
}
for my $weighted (0, 1) {
    my $bot = setup_1385($weighted);
    invoke_1385($bot, 'vote', ['1'], 'Alice', '#test');
    invoke_1385($bot, 'vote', ['2'], 'Bob', '#test');
    my $expected = state_1385($bot);
    $expected->[0]{'#test'}{active} = 0;
    $NOW = 2061;

    @wire = ();
    my $stop = invoke_1385($bot, 'pollstop', [], 'Creator', '#TeSt');
    my $mode = $weighted ? 'weighted' : 'ordinary';
    is_deeply([$stop, state_1385($bot), \@wire],
        [['', [], []], $expected,
         [['public','#TeSt','Poll expired. Use !pollresult to see results.']]],
        "$mode: stop observes expiry without changing ballots, metrics, audit or other polls");

    @wire = ();
    invoke_1385($bot, 'pollstop', [], 'Creator', '#TeSt');
    is_deeply([state_1385($bot), \@wire],
        [$expected, [['notice','Creator','No active poll.']]],
        "$mode: a second stop reports no active poll privately");

    @wire = ();
    invoke_1385($bot, 'pollresult', [], 'Reader', '#TeSt');
    my $outcome = $weighted ? '  Winner: Oui (75% weighted)' : '  Tie: Oui:3, Non:1';
    is($wire[0][2],
        'Closed poll' . ($weighted ? ' [weighted]' : '') . ': "Thé ?" (2 vote(s))' . $outcome,
        "$mode: final results still reflect all ballots after expiry");
}
{
    my $bot = setup_1385(1);
    invoke_1385($bot, 'vote', ['2']);
    @wire = (); @audit = ();
    $NOW = 2060;
    invoke_1385($bot, 'pollstop', [], 'Creator');
    is_deeply([$bot->{_polls}{'#test'}{active}, \@wire, \@audit,
               $bot->{metrics}{mediabot_poll_closed_total}, $bot->{metrics}{mediabot_poll_duration_seconds}],
        [0, [['public','#test','Poll closed (1 vote(s)). Winner: Non (1 vote(s), weighted score 1/1, 100%). Use !pollresult for details.']],
         [['#test','pollstop','']], 1, 60],
        'manual stop at the exact deadline still reports the winner, records metrics and is audited');
}
done_testing;
