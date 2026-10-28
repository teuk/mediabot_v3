use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use Storable qw(dclone);
use Mediabot::Mediabot;
use Mediabot::Context;
binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
{
    package MB1000::DBI; our @ISA = ('DBI');
    package MB1000::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($db, $sql, @rest) = @_;
        my $write = $sql =~ /^UPDATE USER SET birthday = /;
        if ($write) {
            $db->{private_prepares}++;
            return $db->set_err(1,'private birthday prepare detail')
                if ($db->{private_fault}//'') eq 'prepare';
        }
        my $sth = $db->SUPER::prepare($sql,@rest);
        $sth->{private_write} = $write ? 1 : 0 if $sth;
        return $sth;
    }
    package MB1000::DBI::st; our @ISA = ('DBI::st');
    sub execute {
        my ($sth,@bind) = @_;
        my $db = $sth->{Database};
        my $fault = $db->{private_fault}//'';
        if ($sth->{private_write}) {
            $db->{private_executes}++;
            return $sth->set_err(1,'private birthday execute detail') if $fault eq 'execute';
        }
        my $rv = $sth->SUPER::execute(@bind);
        if ($sth->{private_write} && $rv) {
            return $sth->set_err(1,'private birthday lost acknowledgement') if $fault eq 'lost_ack';
            return '0E0' if $fault eq 'zero_rows';
        }
        return $rv;
    }
    sub finish {
        my ($sth) = @_;
        if ($sth->{private_write}) {
            $sth->{Database}{private_finished}++;
            die "private cleanup detail\n" if $sth->{Database}{private_cleanup_failure};
        }
        return $sth->SUPER::finish;
    }
    package MB1000::Log;
    sub log {
        push @{$_[0]{entries}}, [@_[1,2]];
        die "private logger detail\n" if $_[0]{fail};
        return 1;
    }
    package MB1000::User;
    sub is_authenticated { $_[0]{auth} }
    sub has_level { $_[1] eq 'Administrator' && $_[0]{admin} }
    package MB1000::IRC; sub nick_folded { 'testbot' }
}
$INC{'MB1000/DBI.pm'} = __FILE__;
my (@wire,@audit,@warnings);
local $SIG{__WARN__} = sub { push @warnings, @_ };
no warnings qw(redefine once);
local *Mediabot::UserCommands::botNotice = sub { push @wire, ['notice',$_[1],$_[2]]; 1 };
local *Mediabot::UserCommands::botPrivmsg = sub { push @wire, ['public',$_[1],$_[2]]; 1 };
local *Mediabot::UserCommands::logBot = sub { push @audit, [@_[2..$#_]]; 1 };
sub setup_1375 {
    my ($raise) = @_;
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:','','',
        {RootClass=>'MB1000::DBI',RaiseError=>$raise,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
    $db->do('CREATE TABLE USER(id_user INTEGER PRIMARY KEY,nickname TEXT,birthday TEXT)');
    $db->do('INSERT INTO USER VALUES(?,?,?)',undef,@$_) for
        [1,'Alice','1990-10-28'],[2,'Bob',undef],[3,'Zoé','11-02'];
    my $bot = Mediabot->new({}); $bot->{dbh} = $db;
    $bot->{logger} = bless {entries=>[]}, 'MB1000::Log';
    $bot->{irc} = bless {}, 'MB1000::IRC';
    return ($bot,$db);
}
sub rows_1375 { $_[0]->selectall_arrayref('SELECT * FROM USER ORDER BY id_user') }
sub invoke_1375 {
    my ($bot,$args,$auth,$admin) = @_;
    @wire = (); @audit = (); $bot->{logger}{entries} = [];
    my $ctx = Mediabot::Context->new(bot=>$bot,nick=>'Caller',channel=>'#test',
        command=>'birthday',args=>$args,message=>'fixture');
    $ctx->{_user_fetched} = 1;
    $ctx->{user} = bless {auth=>$auth//1,admin=>$admin//1}, 'MB1000::User';
    my $ok = eval { $bot->command_registry->handler_for('birthday','public')->($ctx); 1 };
    return $ok ? '' : "$@";
}
for my $mode (qw(add del)) {
    for my $raise (0,1) {
        my (@actual,@expected);
        for my $fault (qw(prepare execute)) {
            my ($bot,$db) = setup_1375($raise); my $before = rows_1375($db);
            $db->{private_fault} = $fault;
            my @args = ($mode,'user','Alice'); push @args,'27/10/1990' if $mode eq 'add';
            my $error = invoke_1375($bot,\@args); $db->{private_fault} = '';
            push @actual, [$fault,$error,dclone(\@wire),dclone(\@audit),
                dclone($bot->{logger}{entries}),rows_1375($db),$db->{private_finished}//0];
            push @expected, [$fault,'',[['notice','Caller','Database error.']],[],
                [[1,"_birthday_${mode}_ctx() database write failed."]],$before,$fault eq 'prepare' ? 0 : 1];
        }
        is_deeply(\@actual,\@expected,
            "$mode RaiseError=$raise: failed UPDATE is contained, privately reported and never acknowledged as success");
    }
}
for my $case (
    [[qw(add user Alice 27/10/1990)],'1990-10-27','Birthday set to 1990-10-27 for Alice.','birthday add','Alice 1990-10-27'],
    [[qw(add user Alice 29/02)],'02-29','Birthday set to 02-29 for Alice.','birthday add','Alice 02-29'],
    [[qw(add user Alice)],undef,'Birthday cleared for Alice.','birthday add','Alice '],
    [[qw(del user Alice)],undef,'Birthday cleared for Alice.','birthday del','Alice']) {
    my ($args,$value,$notice,$action,$detail) = @$case;
    my ($bot,$db) = setup_1375(1); my $expected = rows_1375($db); $expected->[0][2] = $value;
    my $error = invoke_1375($bot,$args);
    is_deeply([$error,\@wire,\@audit,rows_1375($db),$db->{private_executes}//0],
        ['', [['notice','Caller',$notice]], [[undef,$action,$detail]], $expected,1],
        "healthy @$args: exact stored date, private acknowledgement, audit and unrelated users preserved");
}
{
    my (@actual,@expected);
    for my $mode (qw(add del)) {
        my ($bot,$db) = setup_1375(1); my $before = rows_1375($db);
        $db->{private_fault} = 'zero_rows';
        my $error = invoke_1375($bot,[$mode,'user','Bob']);
        push @actual, [$error,dclone(\@wire),dclone(\@audit),rows_1375($db),$db->{private_executes}//0];
        push @expected, ['', [['notice','Caller','Birthday cleared for Bob.']],
            [[undef,"birthday $mode",$mode eq 'add' ? 'Bob ' : 'Bob']],$before,1];
    }
    is_deeply(\@actual,\@expected,'true zero-row DBI success remains valid when clearing an already empty birthday');
}
for my $raise (0,1) {
    my (@actual,@expected);
    for my $mode (qw(add del)) {
        my ($bot,$db) = setup_1375($raise); my $expected_rows = rows_1375($db);
        $expected_rows->[0][2] = $mode eq 'add' ? '1990-10-27' : undef;
        $db->{private_fault} = 'lost_ack';
        my @args = ($mode,'user','Alice'); push @args,'27/10/1990' if $mode eq 'add';
        my $error = invoke_1375($bot,\@args); $db->{private_fault} = '';
        push @actual, [$error,dclone(\@wire),dclone(\@audit),rows_1375($db),$db->{private_executes}//0];
        push @expected, ['', [['notice','Caller','Database error.']],[],$expected_rows,1];
    }
    is_deeply(\@actual,\@expected,
        "RaiseError=$raise: lost write acknowledgement causes no success/audit, automatic retry or claim of unchanged data");
}
{
    my (@actual,@expected);
    for my $mode (qw(add del)) {
        my ($bot,$db) = setup_1375(0); my $before = rows_1375($db);
        $db->{private_fault} = 'execute'; $db->{private_cleanup_failure} = 1;
        $bot->{logger}{fail} = 1;
        my @args = ($mode,'user','Alice'); push @args,'27/10/1990' if $mode eq 'add';
        my $error = invoke_1375($bot,\@args); $db->{private_fault} = '';
        push @actual, [$error,dclone(\@wire),dclone(\@audit),rows_1375($db),$db->{private_finished}//0];
        push @expected, ['', [['notice','Caller','Database error.']],[],$before,1];
    }
    is_deeply(\@actual,\@expected,'cleanup and error-logger failures cannot override an unsuccessful UPDATE');
}
{
    my (@actual,@expected);
    for my $mode (qw(add del)) {
        my ($bot,$db) = setup_1375(1); my $expected_rows = rows_1375($db);
        $expected_rows->[0][2] = $mode eq 'add' ? '1990-10-27' : undef;
        $db->{private_cleanup_failure} = 1;
        my @args = ($mode,'user','Alice'); push @args,'27/10/1990' if $mode eq 'add';
        my $error = invoke_1375($bot,\@args);
        push @actual, [$error,dclone(\@wire),dclone(\@audit),rows_1375($db),$db->{private_executes}//0];
        push @expected, ['', [['notice','Caller',$mode eq 'add'
            ? 'Birthday set to 1990-10-27 for Alice.' : 'Birthday cleared for Alice.']],
            [[undef,"birthday $mode",$mode eq 'add' ? 'Alice 1990-10-27' : 'Alice']],$expected_rows,1];
    }
    is_deeply(\@actual,\@expected,'failed cleanup after a confirmed UPDATE preserves its acknowledgement and single audit');
}
{
    my ($bot,$db) = setup_1375(1); my $before = rows_1375($db); my @actual;
    for my $case (
        [[qw(add user Alice 27/10)],0,1,'You must be logged in to use this command - /msg testbot login username password'],
        [[qw(del user Alice)],1,0,'Your level does not allow you to use this command.'],
        [[qw(add user Alice 31/02)],1,1,'Invalid birthday date.'],
        [[qw(add user Missing 27/10)],1,1,'Unknown user: Missing'],
        [[qw(del user Missing)],1,1,'Unknown user: Missing']) {
        my ($args,$auth,$admin,$notice) = @$case;
        my $error = invoke_1375($bot,$args,$auth,$admin);
        push @actual, [$error,dclone(\@wire),dclone(\@audit),$notice];
    }
    is_deeply([\@actual,rows_1375($db),$db->{private_prepares}//0],
        [[map { ['', [['notice','Caller',$_->[3]]], [], $_->[3]] } @actual],$before,0],
        'authentication, role, date validation and unknown-user guards still prevent every UPDATE');
}
is_deeply(\@warnings,[],'birthday writes and clearing through add emit no warnings');
done_testing;
