use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use Mediabot::DBCommands qw(mbDbCommand);
use MockMessage;

binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
{
    package MB1012::DB;
    sub prepare {
        my ($self, $sql) = @_;
        return $self->{real}->prepare($sql) unless $sql =~ /^UPDATE PUBLIC_COMMANDS SET hits=hits\+1/;
        push @{$self->{calls}}, ['prepare', $sql];
        die "private update prepare detail\n" if $self->{fault} eq 'prepare_die';
        return undef if $self->{fault} eq 'prepare_false';
        return bless {owner=>$self, real=>$self->{real}->prepare($sql)}, 'MB1012::Statement';
    }
    package MB1012::Statement;
    sub execute {
        my ($self, @bind) = @_;
        my $db = $self->{owner};
        push @{$db->{calls}}, ['execute', @bind];
        die "private update execute detail\n" if $db->{fault} eq 'execute_die';
        return undef if $db->{fault} eq 'execute_false';
        $db->{real}->do('DELETE FROM PUBLIC_COMMANDS WHERE id_public_commands = ?', undef, $bind[0])
            if $db->{fault} eq 'zero_rows';
        my $result = $self->{real}->execute(@bind);
        die "private lost acknowledgement detail\n" if $db->{fault} eq 'lost_ack';
        return $result;
    }
    sub finish {
        my ($self) = @_;
        push @{$self->{owner}{calls}}, ['finish'];
        $self->{real}->finish;
        die "private cleanup detail\n" if $self->{owner}{fault} eq 'finish_die';
        return 1;
    }
    package MB1012::Logger;
    sub log {
        my ($self, $level, $text) = @_;
        if ($level == 1) {
            $self->{attempts}++;
            die "private failure logger detail\n" if $self->{throws};
            push @{$self->{errors}}, $text;
        }
        return 1;
    }
}
my @wire;
no warnings qw(redefine once);
local *Mediabot::DBCommands::botPrivmsg = sub { push @wire, ['public', $_[1], $_[2]]; 1 };
local *Mediabot::DBCommands::botAction = sub { push @wire, ['action', $_[1], $_[2]]; 1 };
my $update = 'UPDATE PUBLIC_COMMANDS SET hits=hits+1 WHERE id_public_commands=?';
my $failure = 'mbDbCommand() hit statistics update failed';
sub run_1387 {
    my ($fault, $kind, $state, $log_throws) = @_;
    $state //= 'valid';
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '',
        {RaiseError=>1, PrintError=>0, AutoCommit=>1, sqlite_unicode=>1});
    $dbh->do('CREATE TABLE PUBLIC_COMMANDS (id_public_commands INTEGER PRIMARY KEY, command TEXT,
        action TEXT, description TEXT, hits INTEGER, active INTEGER)');
    my $action = $state eq 'bad_target' ? 'PRIVMSG #other forbidden'
        : $state eq 'bad_template' ? "$kind %c %rand{2,1}"
        : "$kind %c Salut %N — %1";
    $dbh->do('INSERT INTO PUBLIC_COMMANDS VALUES (1, ?, ?, ?, 12, ?)', undef,
        'café', $action, 'fixture', $state eq 'held' ? 0 : 1);
    $dbh->do("INSERT INTO PUBLIC_COMMANDS VALUES (2, 'other', 'PRIVMSG %c other', 'fixture', 41, 1)");
    my $db = bless {real=>$dbh, fault=>$fault, calls=>[]}, 'MB1012::DB';
    my $logger = bless {errors=>[], attempts=>0, throws=>$log_throws}, 'MB1012::Logger';
    my $bot = {dbh=>$db, logger=>$logger};
    my $message = MockMessage->from_channel(prefix=>'Alice!u@example.invalid', channel=>'#test', text=>'fixture');
    @wire = ();
    my ($result, $error, @warnings);
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $error = eval {
            $result = mbDbCommand($bot, $message, '#test', 'Alice',
                $state eq 'missing' ? 'missing' : "cafe\x{301}", 'Anaïs');
            1;
        } ? '' : "$@";
    }
    my $counts = $dbh->selectall_arrayref('SELECT id_public_commands, hits FROM PUBLIC_COMMANDS ORDER BY id_public_commands');
    my $observation = {result=>$result, error=>$error, warnings=>\@warnings, wire=>[@wire],
        counts=>$counts, calls=>$db->{calls}, errors=>$logger->{errors}, log_attempts=>$logger->{attempts}};
    $dbh->disconnect;
    return $observation;
}
sub expected_1387 {
    my ($kind, $fault, $throws) = @_;
    my $prepare_only = $fault =~ /^prepare_/;
    my $unconfirmed = $prepare_only || $fault =~ /^execute_/ || $fault eq 'lost_ack';
    my @calls = (['prepare', $update]);
    push @calls, ['execute',1], ['finish'] unless $prepare_only;
    my $counts = $fault eq 'zero_rows' ? [[2,41]]
        : [[$fault eq 'lost_ack' || !$unconfirmed ? (1,13) : (1,12)], [2,41]];
    return {result=>1, error=>'', warnings=>[],
        wire=>[[$kind eq 'ACTION' ? 'action' : 'public','#test','Salut Alice — Anaïs']],
        counts=>$counts, calls=>\@calls, errors=>$unconfirmed && !$throws ? [$failure] : [],
        log_attempts=>$unconfirmed ? 1 : 0};
}
for my $group (
    ['prepare', [qw(prepare_die prepare_false)]],
    ['execute', [qw(execute_die execute_false)]],
) {
    my (@actual, @expected);
    for my $fault (@{$group->[1]}) {
        for my $kind (qw(PRIVMSG ACTION)) {
            push @actual, run_1387($fault,$kind);
            push @expected, expected_1387($kind,$fault);
        }
    }
    is_deeply(\@actual, \@expected,
        "statistics $group->[0] failures cannot suppress a valid message/action or expose private driver details");
}
is_deeply(run_1387('lost_ack','PRIVMSG'), expected_1387('PRIVMSG','lost_ack'),
    'a lost acknowledgement still sends one response and never retries the already applied increment');
is_deeply(run_1387('finish_die','ACTION'), expected_1387('ACTION','finish_die'),
    'cleanup failure after a successful increment cannot suppress the action or change its count');
is_deeply(run_1387('execute_false','PRIVMSG','valid',1), expected_1387('PRIVMSG','execute_false',1),
    'failure logging is best effort and cannot suppress the response');
is_deeply([run_1387('','PRIVMSG'),run_1387('','ACTION'),run_1387('zero_rows','PRIVMSG')],
    [expected_1387('PRIVMSG',''),expected_1387('ACTION',''),expected_1387('PRIVMSG','zero_rows')],
    'normal atomic increments and a concurrent deletion retain valid output and do not touch another command');
{
    my (@actual, @expected);
    for my $state (qw(missing held bad_target bad_template)) {
        my $got = run_1387('execute_die','PRIVMSG',$state);
        # Existing invalid-template diagnostics are outside the statistics path.
        delete @{$got}{qw(errors log_attempts)};
        push @actual, $got;
        push @expected, {result=>$state eq 'missing' || $state eq 'held' ? 0 : 1,
            error=>'', warnings=>[], wire=>[], counts=>[[1,12],[2,41]], calls=>[]};
    }
    is_deeply(\@actual, \@expected, 'missing, held and invalid commands never reach the hit writer or emit a response');
}
done_testing;
