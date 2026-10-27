use strict;
use warnings;
use Test::More;
use DBI;
use Storable qw(dclone);
use Mediabot::Mediabot;
use Mediabot::Context;
use MockUser;

# Queue the real command's asynchronous completion; no HTTP, sleep or worker.
# SQLite translates only the score UPSERT dialect used by the answer handler.
{
    package MB983::DBI; our @ISA = ('DBI');
    package MB983::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($db, $sql, @rest) = @_;
        $sql =~ s/ON DUPLICATE KEY UPDATE/ON CONFLICT(id_channel,nick) DO UPDATE SET/;
        $sql =~ s/NOW\(\)/CURRENT_TIMESTAMP/g;
        return $db->SUPER::prepare($sql, @rest);
    }
    package MB983::DBI::st; our @ISA = ('DBI::st');
    package MB983::Log; sub log {1}
    package MB983::Conf; sub get {30}
    package MB983::Channel; sub get_id {$_[0]{id}}
    package MB983::Metrics; sub inc {$_[0]{$_[1]}++; 1}
    package MB983::Bot; our @ISA = ('Mediabot');
    sub botNotice { push @{$_[0]{wire}}, ['notice', $_[1], $_[2]]; 1 }
}
$INC{'MB983/DBI.pm'} = __FILE__;
no warnings qw(redefine once);
local *Mediabot::Helpers::botPrivmsg = sub {push @{$_[0]{wire}}, ['public', $_[1], $_[2]]; 1};
local *Mediabot::UserCommands::botPrivmsg = sub {goto &Mediabot::Helpers::botPrivmsg};
local *Mediabot::UserCommands::botNotice = sub {push @{$_[0]{wire}}, ['notice', $_[1], $_[2]]; 1};
local *Mediabot::UserCommands::logBot = sub {push @{$_[0]{logs}}, [@_[2..4]]; 1};
local *Mediabot::UserCommands::_trivia_fetch_async = sub {
    my ($bot, $cat, $diff, $cb) = @_;
    push @{$bot->{callbacks}}, $cb;
    return 1;
};

my $master = MockUser->new(level => 'Master', auth => 1);
sub setup_1359 {
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {
        RootClass => 'MB983::DBI', RaiseError => 1, PrintError => 0});
    $db->do('CREATE TABLE TRIVIA_SCORES(id_channel INTEGER, nick TEXT, score INTEGER,
        last_correct TEXT, PRIMARY KEY(id_channel,nick))');
    $db->do("INSERT INTO TRIVIA_SCORES VALUES(2,'bob',42,'2026-10-27')");
    my $bot = Mediabot->new({dbh => $db});
    bless $bot, 'MB983::Bot';
    $bot->{logger} = bless {}, 'MB983::Log';
    $bot->{conf} = bless {}, 'MB983::Conf';
    $bot->{metrics} = bless {}, 'MB983::Metrics';
    $bot->{channels} = {map {$_->[0] => bless({id => $_->[1]}, 'MB983::Channel')}
        ['#test', 1], ['#other', 2]};
    $bot->{wire} = []; $bot->{callbacks} = []; $bot->{logs} = [];
    return $bot;
}
sub invoke_1359 {
    my ($entry, $bot, $command, $channel, $user, @args) = @_;
    my $ctx = Mediabot::Context->new(bot => $bot, nick => 'Alice', channel => $channel,
        command => $command, args => \@args);
    $ctx->{_user_fetched} = 1; $ctx->{user} = $user;
    if ($entry eq 'registry') {
        return $bot->command_registry->handler_for($command, 'public')->($ctx);
    }
    my %handler = (trivia => 'mbTrivia_ctx', triviastop => 'mbTriviaStop_ctx');
    no strict 'refs';
    return &{"${entry}::$handler{$command}"}($ctx);
}
sub result_1359 {
    return {ok => 1, question => {question => 'Capital of France?', correct_answer => 'Paris',
        incorrect_answers => ['Rome', 'Berlin', 'Madrid'], category => 'Geography', difficulty => 'easy'}};
}
sub state_1359 { dclone({map {$_ => $_[0]{$_}} qw(_trivia _trivia_fetch metrics logs)}) }
sub persisted_1359 { $_[0]{dbh}->selectall_arrayref('SELECT * FROM TRIVIA_SCORES ORDER BY id_channel,nick') }
sub text_1359 { join(' ', map {$_->[2]} @{$_[0]{wire}}) }

for my $entry (qw(Mediabot::Games::Trivia Mediabot::UserCommands Mediabot registry)) {
    for my $stage (qw(first_fetch next_fetch between timeout active)) {
        my $label = "$entry / $stage";
        my $bot = setup_1359();
        # Another channel has both a series and an outstanding request.
        invoke_1359($entry, $bot, 'trivia', '#other', $master, 'start', 4);
        my $other = dclone($bot->{_trivia}{'#other'});
        my $other_pending = dclone($bot->{_trivia_fetch}{'#other'});
        invoke_1359($entry, $bot, 'trivia', '#test', $master, 'start', 3);
        my $old = $bot->{callbacks}[-1];
        if ($stage ne 'first_fetch') {
            $old->(result_1359());
            if ($stage eq 'timeout') {
                $bot->{_trivia}{'#test'}{deadline} = time() - 1;
                Mediabot::Games::Trivia::checkTriviaAnswer($bot, 'Alice', '#test', 'irrelevant');
            } elsif ($stage ne 'active') {
                Mediabot::Games::Trivia::checkTriviaAnswer($bot, 'Alice', '#test', 'Paris');
                is($bot->{dbh}->selectrow_array("SELECT score FROM TRIVIA_SCORES WHERE id_channel=1 AND nick='alice'"),
                    1, "$label: an answered round really persists its point");
                if ($stage eq 'next_fetch') {
                    invoke_1359($entry, $bot, 'trivia', '#test', $master);
                    $old = $bot->{callbacks}[-1];
                }
            }
        }
        my $persisted = persisted_1359($bot);
        $bot->{wire} = [];
        is(invoke_1359($entry, $bot, 'triviastop', '#test', $master), 1, "$label: stop completes");
        ok(!$bot->{_trivia}{'#test'}{active}, "$label: no active question survives");
        ok(!exists($bot->{_trivia}{'#test'}{multi_total}), "$label: series length is cleared");
        ok(!exists($bot->{_trivia}{'#test'}{multi_current}), "$label: round counter is cleared");
        ok(!exists($bot->{_trivia}{'#test'}{scores}), "$label: abandoned session scores are cleared");
        is($bot->{_trivia}{'#test'}{hint_given}, 0, "$label: hint state is reset");
        ok(!exists($bot->{_trivia_fetch}{'#test'}), "$label: current channel token is invalidated");
        is_deeply($bot->{_trivia}{'#other'}, $other, "$label: another channel's series is unchanged");
        is_deeply($bot->{_trivia_fetch}{'#other'}, $other_pending, "$label: another channel's pending token survives");
        is_deeply(persisted_1359($bot), $persisted, "$label: stop preserves all persistent scores");
        is(scalar @{$bot->{wire}}, 1, "$label: exactly one stop acknowledgement");
        if ($stage eq 'active') {
            is_deeply($bot->{wire}[0], ['public', '#test', 'Trivia stopped by Alice. Answer: Paris'],
                "$label: existing live-question response is preserved");
        } else {
            is($bot->{wire}[0][0], 'notice', "$label: cancellation stays private");
            is($bot->{wire}[0][1], 'Alice', "$label: cancellation addresses caller");
            like(text_1359($bot), $stage =~ /fetch/ ? qr/Pending trivia question request cancelled/
                : qr/Trivia game stopped/, "$label: ongoing series is acknowledged as stopped");
            unlike(text_1359($bot), qr/Answer:|No active trivia/, "$label: no stale answer or false absence");
        }
        my $stopped = state_1359($bot);
        $bot->{wire} = [];
        $old->(result_1359()); $old->({ok => 0, error => 'http_timeout'});
        is_deeply(state_1359($bot), $stopped, "$label: late success/failure cannot revive the stopped game");
        is(scalar @{$bot->{wire}}, 0, "$label: late completions are silent");

        # Repeating stop is harmless and a plain new question is not a resumption.
        invoke_1359($entry, $bot, 'triviastop', '#test', $master);
        like(text_1359($bot), qr/No active trivia/, "$label: repeat stop reports no active game");
        is_deeply(state_1359($bot), $stopped, "$label: repeat stop changes no state");
        $bot->{wire} = [];
        invoke_1359($entry, $bot, 'trivia', '#test', $master);
        my $new = $bot->{callbacks}[-1];
        my $new_pending = dclone($bot->{_trivia_fetch}{'#test'});
        $old->(result_1359()); $old->({ok => 0, error => 'fetch'});
        is_deeply($bot->{_trivia_fetch}{'#test'}, $new_pending, "$label: old callback cannot consume the new request");
        $new->(result_1359());
        ok($bot->{_trivia}{'#test'}{active}, "$label: fresh question opens normally");
        ok(!$bot->{_trivia}{'#test'}{multi_total}, "$label: fresh question is not part of the cancelled series");
        ok(!$bot->{_trivia}{'#test'}{multi_current}, "$label: fresh question inherits no round counter");
        is_deeply($bot->{_trivia}{'#test'}{scores}, {}, "$label: fresh question starts with empty session scores");
        unlike(text_1359($bot), qr/Round \d+\/3/, "$label: no cancelled-series round announcement");
        my $opened = state_1359($bot);
        $new->(result_1359());
        is_deeply(state_1359($bot), $opened, "$label: duplicate completion cannot reopen the question");
        is_deeply(persisted_1359($bot), $persisted, "$label: cancellation and restart never erase earned DB points");
    }

    # Access control runs before request or series mutation.
    for my $user (undef, MockUser->new(level => 'Master', auth => 0),
            MockUser->new(level => 'User', auth => 1)) {
        my $bot = setup_1359();
        invoke_1359($entry, $bot, 'trivia', '#test', $master, 'start', 3);
        my $before = state_1359($bot);
        $bot->{wire} = [];
        invoke_1359($entry, $bot, 'triviastop', '#test', $user);
        is_deeply(state_1359($bot), $before, "$entry: unauthorized stop preserves pending game");
        like(text_1359($bot), qr/logged in|level does not allow/, "$entry: existing authorization denial");
    }
    {
        my $bot = setup_1359();
        invoke_1359($entry, $bot, 'trivia', '#test', $master);
        my $late = $bot->{callbacks}[-1];
        invoke_1359($entry, $bot, 'triviastop', '#test', $master);
        ok(!exists($bot->{_trivia_fetch}), "$entry: last pending request removes empty pending map");
        ok(!exists($bot->{_trivia}{'#test'}), "$entry: cancelling a single fetch creates no phantom game");
        $late->(result_1359());
        ok(!exists($bot->{_trivia}{'#test'}), "$entry: cancelled single question cannot arrive later");
    }
    {
        my $bot = setup_1359();
        invoke_1359($entry, $bot, 'trivia', '#test', $master, 'start', 1);
        $bot->{callbacks}[-1]->(result_1359());
        Mediabot::Games::Trivia::checkTriviaAnswer($bot, 'Alice', '#test', 'Paris');
        my $finished = state_1359($bot);
        $bot->{wire} = [];
        invoke_1359($entry, $bot, 'triviastop', '#test', $master);
        is_deeply(state_1359($bot), $finished, "$entry: no-op stop preserves a completed game's scoreboard");
        like(text_1359($bot), qr/No active trivia/, "$entry: completed game keeps existing no-active response");
    }
}
done_testing;
