use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use Storable qw(dclone);
BEGIN {
    $ENV{TZ} = 'UTC'; require POSIX; POSIX::tzset(); require Time::Local;
    $MB994::now = Time::Local::timegm(0,0,12,28,9,2026);
    *CORE::GLOBAL::time = sub () { $MB994::now };
}
use Mediabot::Mediabot;
use Mediabot::Context;
binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
{
    package MB994::DBI; our @ISA = ('DBI');
    package MB994::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($db, $sql, @rest) = @_;
        my $read = $sql =~ /SELECT\s+(?:birthday|nickname,\s*birthday)\s+FROM\s+USER/i;
        return $db->set_err(1,'private birthday prepare detail')
            if $read && ($db->{private_fault}//'') eq 'prepare';
        my $sth = $db->SUPER::prepare($sql, @rest);
        $sth->{private_read} = $read ? 1 : 0 if $sth;
        return $sth;
    }
    package MB994::DBI::st; our @ISA = ('DBI::st');
    sub execute {
        my ($sth, @bind) = @_;
        $sth->{private_fetched} = 0;
        return $sth->set_err(1,'private birthday execute detail')
            if $sth->{private_read} && ($sth->{Database}{private_fault}//'') eq 'execute';
        return $sth->SUPER::execute(@bind);
    }
    sub fetchrow_hashref {
        my ($sth, @rest) = @_;
        my $fault = $sth->{Database}{private_fault}//'';
        return $sth->set_err(1,'private birthday fetch detail')
            if $sth->{private_read} && ($fault eq 'fetch_first'
                || ($fault eq 'fetch_after_one' && $sth->{private_fetched}));
        my $row = $sth->SUPER::fetchrow_hashref(@rest);
        $sth->{private_fetched}++ if $row;
        return $row;
    }
    sub finish {
        my ($sth) = @_;
        if ($sth->{private_read}) {
            $sth->{Database}{private_finished}++;
            die "private cleanup detail\n" if $sth->{Database}{private_cleanup_failure};
        }
        return $sth->SUPER::finish;
    }
    package MB994::Log;
    sub log {
        push @{$_[0]{entries}}, [@_[1,2]];
        die "private logger detail\n" if $_[0]{fail};
        return 1;
    }
}
$INC{'MB994/DBI.pm'} = __FILE__;
my (@wire, @audit, @warnings);
local $SIG{__WARN__} = sub { push @warnings, @_ };
no warnings qw(redefine once);
local *Mediabot::UserCommands::botNotice = sub { push @wire, ['notice',$_[1],$_[2]]; 1 };
local *Mediabot::UserCommands::botPrivmsg = sub { push @wire, ['public',$_[1],$_[2]]; 1 };
local *Mediabot::UserCommands::logBot = sub { push @audit, [@_[2..$#_]]; 1 };
sub setup_1369 {
    my ($raise) = @_;
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:','','',
        {RootClass=>'MB994::DBI',RaiseError=>$raise,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
    $db->do('CREATE TABLE USER(id_user INTEGER PRIMARY KEY,nickname TEXT,birthday TEXT)');
    $db->do('INSERT INTO USER VALUES(?,?,?)', undef, @$_) for
        [1,'Alice','1990-10-28'], [2,'Bob',undef], [3,'Zoé','11-02'],
        [4,'Far','12-05'], [5,'Broken','invalid'];
    my $bot = Mediabot->new({}); $bot->{dbh} = $db;
    $bot->{logger} = bless {entries=>[]}, 'MB994::Log';
    return ($bot,$db);
}
sub rows_1369 { $_[0]->selectall_arrayref('SELECT * FROM USER ORDER BY id_user') }
sub invoke_1369 {
    my ($bot, $args, $channel) = @_;
    @wire = (); @audit = ();
    my $ctx = Mediabot::Context->new(bot=>$bot,nick=>'Caller',channel=>$channel,
        command=>'birthday',args=>$args);
    my $ok = eval { $bot->command_registry->handler_for('birthday','public')->($ctx); 1 };
    return $ok ? '' : "$@";
}
for my $raise (0,1) {
    for my $case (['Alice','prepare'], ['Alice','execute'], ['Alice','fetch_first'],
                  ['next','prepare'], ['next','execute'], ['next','fetch_first'],
                  ['next','fetch_after_one']) {
        my ($arg, $fault) = @$case;
        my ($bot,$db) = setup_1369($raise); my $before = rows_1369($db);
        $db->{private_fault} = $fault;
        my $error = invoke_1369($bot, [$arg], '#test');
        $db->{private_fault} = '';
        my $operation = $arg eq 'next' ? '_birthday_next_ctx' : 'userBirthday_ctx';
        is_deeply([$error, \@wire, \@audit, $bot->{logger}{entries},
                   $db->{private_finished}//0, rows_1369($db)],
            ['', [['notice','Caller','Database error.']], [],
             [[1,"$operation() database read failed."]], $fault eq 'prepare' ? 0 : 1, $before],
            "RaiseError=$raise $arg/$fault: no exception, false absence, partial list or data change");
    }
}
{
    my ($bot,$db) = setup_1369(1); my $before = rows_1369($db); my @actual;
    for my $case (['Alice','#test'], ['Alice',undef], ['Bob','#test'], ['Missing','#test'], ['next','#test']) {
        my ($arg,$channel) = @$case;
        my $error = invoke_1369($bot, [$arg], $channel);
        push @actual, [$error, dclone(\@wire), dclone(\@audit)];
    }
    my $after_reads = rows_1369($db);
    $db->do('UPDATE USER SET birthday=NULL');
    my $error = invoke_1369($bot, ['next'], '#test');
    push @actual, [$error, dclone(\@wire), dclone(\@audit)];
    is_deeply([\@actual,$after_reads], [[
        ['', [['public','#test',"Alice's birthday is 1990-10-28"]], []],
        ['', [['notice','Caller',"Alice's birthday is 1990-10-28"]], []],
        ['', [['public','#test','User Bob has no defined birthday.']], []],
        ['', [['public','#test','Unknown user Missing']], []],
        ['', [['notice','Caller','Upcoming birthdays in the next 30 days:'],
              ['notice','Caller','  Alice : 1990-10-28 (today)'],
              ['notice','Caller','  Zoé : 11-02 (in 5d)']], []],
        ['', [['notice','Caller','No upcoming birthdays in the next 30 days.']], []],
    ],$before], 'confirmed reads preserve data, public/private lookup, null birthday, absence and the calendar window');
}
{
    my ($bot,$db) = setup_1369(1); my $before = rows_1369($db);
    $db->{private_fault} = 'fetch_after_one'; $db->{private_cleanup_failure} = 1;
    $bot->{logger}{fail} = 1;
    my $error = invoke_1369($bot, ['next'], '#test'); $db->{private_fault} = '';
    is_deeply([$error, \@wire, \@audit, rows_1369($db)],
        ['', [['notice','Caller','Database error.']], [], $before],
        'cleanup and logger failures cannot hide a failed read or publish its partial result');
}
is_deeply(\@warnings, [], 'birthday reads emit no warnings');
done_testing;
