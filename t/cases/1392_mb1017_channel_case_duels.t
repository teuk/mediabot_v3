use strict;
use warnings;
use utf8;
BEGIN {
    our $now = 1_900_000_000;
    our @dice;
    *CORE::GLOBAL::time = sub { $main::now };
    *CORE::GLOBAL::rand = sub (;$) {
        return shift @main::dice if defined($_[0]) && $_[0] == 20 && @main::dice;
        return 0;
    };
}
use Test::More;
use DBI;
use Storable qw(dclone);
use Mediabot::Mediabot;
use Mediabot::Context;

{
    package MB1017::DBI; our @ISA = ('DBI');
    package MB1017::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($db, $sql, @args) = @_;
        # Bridge only the MariaDB upsert dialect; SQLite executes both rows.
        $sql =~ s/ON DUPLICATE KEY UPDATE/ON CONFLICT(id_channel,nick) DO UPDATE SET/;
        $sql =~ s/VALUES\(score\)/excluded.score/g;
        return $db->SUPER::prepare($sql, @args);
    }
    package MB1017::DBI::st; our @ISA = ('DBI::st');
    package MB1017::IRC;
    sub nick_folded { 'mediabot' }
    package MB1017::Channel;
    sub get_id { $_[0]{id} }
    package MB1017::Log;
    sub log { 1 }
    package MB1017::Metrics;
    sub inc { $_[0]{$_[1]}++; 1 }
}
$INC{'MB1017/DBI.pm'} = __FILE__;
no warnings qw(redefine once);
local *Mediabot::Helpers::chanset_enabled = sub { $_[0]{games_enabled} };
local *Mediabot::UserCommands::botPrivmsg = sub {
    push @{$_[0]{wire}}, ['public', $_[1], $_[2]]; 1;
};
local *Mediabot::UserCommands::botNotice = sub {
    push @{$_[0]{wire}}, ['notice', $_[1], $_[2]]; 1;
};
local *Mediabot::UserCommands::logBot = sub { $_[0]{audit}++; 1 };
my @warnings;
local $SIG{__WARN__} = sub { push @warnings, @_ };
sub bot_1392 {
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '',
        {RootClass => 'MB1017::DBI', RaiseError => 1, PrintError => 0});
    $db->do('CREATE TABLE KARMA(id_channel INTEGER,nick TEXT,score INTEGER,PRIMARY KEY(id_channel,nick))');
    my $bot = Mediabot->new({dbh => $db});
    $bot->{irc} = bless {}, 'MB1017::IRC';
    $bot->{logger} = bless {}, 'MB1017::Log';
    $bot->{metrics} = bless {}, 'MB1017::Metrics';
    $bot->{games_enabled} = 1;
    $bot->{wire} = [];
    $bot->{hChannelsNicks} = {'#Test' => [qw(Alice Bob mediabot)], '#Other' => [qw(Alice Bob)]};
    $bot->{channels} = {
        '#test' => bless({id => 1}, 'MB1017::Channel'),
        '#other' => bless({id => 2}, 'MB1017::Channel'),
    };
    return $bot;
}
sub call_1392 {
    my ($bot, $channel, $nick, @args) = @_;
    $bot->{wire} = [];
    my $ctx = Mediabot::Context->new(bot => $bot, channel => $channel, nick => $nick,
        command => 'duel', args => \@args);
    $ctx->{_user_fetched} = 1;
    $bot->command_registry->handler_for('duel', 'public')->($ctx);
    return join ' ', map { $_->[2] } @{$bot->{wire}};
}
sub rows_1392 { $_[0]{dbh}->selectall_arrayref('SELECT id_channel,nick,score FROM KARMA ORDER BY id_channel,nick') }
sub memory_1392 {
    return dclone({map {$_ => $_[0]{$_} // {}}
        qw(_duel_stats _duel_cooldown _duel_streak _duel_last_result)});
}
my $start = $main::now;
{
    my $bot = bot_1392();
    my $before = dclone($bot->{hChannelsNicks});
    my @actual = map { [Mediabot::Helpers::gethChannelsNicksOnChan($bot, $_)] }
        ('#Test', '#test', '#TEST', '#oThEr', '#unknown');
    my $unchanged = dclone($bot->{hChannelsNicks});
    $bot->{hChannelsNicks}{'#test'} = [];
    my @exact_empty = $bot->gethChannelsNicksOnChan('#test');
    is_deeply([\@actual, $unchanged, \@exact_empty],
        [[[qw(Alice Bob mediabot)], [qw(Alice Bob mediabot)], [qw(Alice Bob mediabot)],
          [qw(Alice Bob)], []], $before, []],
        'native membership lookup shares channel letter case, isolates other channels and leaves the nick registry unchanged');
}
{
    my $bot = bot_1392();
    my @actual = map {Mediabot::Helpers::getRandomNick($bot, $_)}
        ('#Test', '#test', '#TEST', '#OTHER', '#unknown');
    $bot->{hChannelsNicks}{'#bad'} = {};
    push @actual, Mediabot::Helpers::getRandomNick($bot, '#bad');
    is_deeply(\@actual, ['Alice','Alice','Alice','Alice','',''],
        'random-nick expansion uses the same channel membership instead of returning an empty nick for case variants');
}
{
    my $bot = bot_1392();
    @main::dice = (19, 0);
    my $text = call_1392($bot, '#tEsT', 'Alice', 'Bob');
    is_deeply([rows_1392($bot), $bot->{_duel_stats},
        $bot->{_duel_cooldown}, $text =~ /wins!/ ? 1 : 0,
        $bot->{metrics}{mediabot_duel_total}, $bot->{audit},
        [map {$_->[1]} @{$bot->{wire}}]],
        [[[1,'alice',1],[1,'bob',-1]], {'#test'=>{alice=>{wins=>1},bob=>{losses=>1}}},
         {'#test'=>{"alice\0bob"=>$start+86400}}, 1, 1, 1, ['#tEsT','#tEsT']],
        'real registry duel recognizes present opponents and records one canonical channel while retaining the reply target');
}
{
    my $bot = bot_1392();
    @main::dice = (19, 0);
    call_1392($bot, '#Test', 'Alice', 'Bob');
    my $before = memory_1392($bot);
    # The native NAMES setter retains the supplied spelling. Existing aliases
    # must not grant a second duel when both snapshots contain the players.
    $bot->sethChannelsNicksOnChan($_, qw(Alice Bob mediabot))
        for ('#test', '#TEST', '#TeSt');
    my @blocked;
    @main::dice = (19, 0);
    for my $channel ('#test', '#TEST', '#TeSt') {
        my $text = call_1392($bot, $channel, 'Bob', 'ALICE');
        push @blocked, $text =~ /cooldown active/ ? 1 : 0;
    }
    is_deeply([\@blocked, rows_1392($bot), memory_1392($bot), [@main::dice], $bot->{audit}],
        [[1,1,1], [[1,'alice',1],[1,'bob',-1]], $before, [19,0], 1],
        'case variants and reversed players cannot bypass the shared 24-hour cooldown or apply more karma');
}
{
    my $bot = bot_1392();
    @main::dice = (19, 0);
    call_1392($bot, '#Test', 'Alice', 'Bob');
    my $stats = call_1392($bot, '#TEST', 'Alice', 'stats', 'ALICE');
    my $top = call_1392($bot, '#test', 'Alice', 'top');
    is_deeply([$stats =~ /alice duel record on #TEST: 1 win\(s\) \/ 0 loss\(es\)/ ? 1 : 0,
              $top =~ /alice: 1W\/0L/ ? 1 : 0, $bot->{audit}, rows_1392($bot)],
        [1,1,1,[[1,'alice',1],[1,'bob',-1]]],
        'duel stats and top show the same confirmed record for differently cased channel targets without more writes');
    $bot->{wire} = [];
    Mediabot::UserCommands::mbLeaderboard_ctx(Mediabot::Context->new(
        bot=>$bot, channel=>'#TEST', nick=>'Alice', args=>['duels']));
    my $board = join ' ', map {$_->[2]} @{$bot->{wire}};
    is_deeply([$board =~ /alice\x02 1/ ? 1 : 0, $board =~ /no data yet/ ? 1 : 0,
        [map {$_->[1]} @{$bot->{wire}}], rows_1392($bot)],
        [1,0,['#TEST','#TEST'],[[1,'alice',1],[1,'bob',-1]]],
        'the existing general leaderboard reads the canonical duel record and keeps its presentation and target');
}
{
    my $bot = bot_1392();
    @main::dice = (19, 0);
    call_1392($bot, '#Test', 'Alice', 'Bob');
    $main::now = $start + 86400;
    @main::dice = (19, 0);
    call_1392($bot, '#TEST', 'Alice', 'Bob');
    @main::dice = (0, 19);
    call_1392($bot, '#OTHER', 'Alice', 'Bob');
    is_deeply([rows_1392($bot), $bot->{_duel_stats}, $bot->{_duel_streak}, $bot->{_duel_last_result},
        $bot->{_duel_cooldown}, $bot->{metrics}{mediabot_duel_total}, $bot->{audit}],
        [[[1,'alice',2],[1,'bob',-2],[2,'alice',-1],[2,'bob',1]],
         {'#test'=>{alice=>{wins=>2},bob=>{losses=>2}}, '#other'=>{bob=>{wins=>1},alice=>{losses=>1}}},
         {'#test'=>{alice=>2,bob=>-2},'#other'=>{bob=>1,alice=>-1}},
         {'#test'=>{alice=>'win',bob=>'loss'},'#other'=>{bob=>'win',alice=>'loss'}},
         {'#test'=>{"alice\0bob"=>$start+172800},'#other'=>{"alice\0bob"=>$start+172800}},3,3],
        'cooldown expiry retains streak continuity across case changes while a genuinely different channel stays independent');
    $main::now = $start;
}
{
    my $bot = bot_1392();
    my @replies;
    $bot->{games_enabled} = 0;
    push @replies, call_1392($bot, '#Test', 'Alice', 'Bob') =~ /Games are disabled/ ? 1 : 0;
    $bot->{games_enabled} = 1;
    push @replies, call_1392($bot, '#Test', 'Alice', 'Alice') =~ /can't duel yourself/ ? 1 : 0;
    push @replies, call_1392($bot, '#Test', 'Alice', 'Absent') =~ /is not on/ ? 1 : 0;
    @main::dice = (9, 9);
    push @replies, call_1392($bot, '#Test', 'Alice', 'Bob') =~ /Draw! No cooldown/ ? 1 : 0;
    $bot->{dbh}->do('DROP TABLE KARMA');
    @main::dice = (19, 0);
    push @replies, call_1392($bot, '#Test', 'Alice', 'Bob') =~ /Duel result not confirmed/ ? 1 : 0;
    # Reading an absent cooldown may autovivify an empty channel bucket.
    # Check outcome leaves, not that harmless implementation detail.
    my $memory = memory_1392($bot);
    for my $table (values %$memory) {
        delete $table->{$_} for grep {!keys %{$table->{$_}}} keys %$table;
    }
    is_deeply([\@replies, $memory, $bot->{metrics}{mediabot_duel_total}//0, $bot->{audit}//0, \@warnings],
        [[1,1,1,1,1], {map {$_=>{}} qw(_duel_stats _duel_cooldown _duel_streak _duel_last_result)}, 0, 0, []],
        'Games, self/absent targets, draws and actual SQL failure still publish no win state, cooldown or success accounting');
}
done_testing;
