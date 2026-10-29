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
    package MB1004::DBI; our @ISA=('DBI');
    package MB1004::DBI::db; our @ISA=('DBI::db');
    sub prepare {
        my ($db,$sql,@rest)=@_;
        my $kind=$sql=~/SELECT\s+COUNT\(\*\)\s+AS\s+nbUsers/i?'total'
            :$sql=~/SELECT\s+description,\s*COUNT\(\*\)/i?'levels':'';
        if ($kind) {
            $db->{private_prepares}++;
            return $db->set_err(1,'private user count prepare detail')
                if ($db->{private_fault}//'') eq "$kind.prepare";
        }
        my $sth=$db->SUPER::prepare($sql,@rest);
        $sth->{private_kind}=$kind if $sth;
        return $sth;
    }
    package MB1004::DBI::st; our @ISA=('DBI::st');
    sub execute {
        my ($sth,@bind)=@_;
        $sth->{private_fetched}=0;
        return $sth->set_err(1,'private user count execute detail')
            if $sth->{private_kind} && ($sth->{Database}{private_fault}//'') eq "$sth->{private_kind}.execute";
        return $sth->SUPER::execute(@bind);
    }
    sub fetchrow_array {
        my ($sth,@rest)=@_;
        my $kind=$sth->{private_kind}//'';
        my $fault=$sth->{Database}{private_fault}//'';
        return () if $kind eq 'total' && $fault eq 'total.no_row';
        if ($kind && ($fault eq "$kind.fetch"
                || ($fault eq "$kind.fetch_after_one" && $sth->{private_fetched}))) {
            $sth->set_err(1,'private user count fetch detail');
            return ();
        }
        my @row=$sth->SUPER::fetchrow_array(@rest);
        $sth->{private_fetched}++ if @row;
        return @row;
    }
    sub finish {
        my ($sth)=@_;
        if ($sth->{private_kind}) {
            $sth->{Database}{private_finished}++;
            $sth->set_err(undef,undef);
            die "private cleanup detail\n" if $sth->{Database}{private_cleanup_failure};
        }
        return $sth->SUPER::finish;
    }
    package MB1004::Log;
    sub log {
        push @{$_[0]{entries}},[@_[1,2]];
        die "private logger detail\n" if $_[0]{fail};
        return 1;
    }
    package MB1004::User;
    sub is_authenticated {$_[0]{auth}}
    sub has_level {$_[1] eq 'Master' && $_[0]{master}}
}
$INC{'MB1004/DBI.pm'}=__FILE__;
my (@wire,@warnings);
local $SIG{__WARN__}=sub {push @warnings,@_};
no warnings qw(redefine once);
local *Mediabot::botNotice=sub {push @wire,['notice',$_[1],$_[2]];1};
local *Mediabot::botPrivmsg=sub {push @wire,['public',$_[1],$_[2]];1};
sub setup_1379 {
    my ($raise,$empty)=@_;
    my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',
        {RootClass=>'MB1004::DBI',RaiseError=>$raise,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
    $db->do('CREATE TABLE USER_LEVEL(id_user_level INTEGER PRIMARY KEY,description TEXT,level INTEGER)');
    $db->do('CREATE TABLE USER(id_user INTEGER PRIMARY KEY,nickname TEXT,id_user_level INTEGER)');
    $db->do('INSERT INTO USER_LEVEL VALUES(?,?,?)',undef,@$_) for
        [1,'Owner',0],[2,'Master',10],[3,'Élève',100];
    unless ($empty) {
        $db->do('INSERT INTO USER VALUES(?,?,?)',undef,@$_) for
            [1,'Alice',1],[2,'Bob',2],[3,'Zoé',3],[4,'Dan',3];
    }
    $db->do('PRAGMA query_only = ON');
    my $bot=Mediabot->new({});$bot->{dbh}=$db;
    $bot->{logger}=bless {entries=>[]},'MB1004::Log';
    return ($bot,$db);
}
sub rows_1379 {$_[0]->selectall_arrayref('SELECT * FROM USER ORDER BY id_user')}
sub invoke_1379 {
    my ($bot,$auth,$master,$channel)=@_;
    @wire=();$bot->{logger}{entries}=[];
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Caller',channel=>$channel,
        command=>'users',args=>[]);
    $ctx->{_user_fetched}=1;
    $ctx->{user}=bless {auth=>$auth//1,master=>$master//1},'MB1004::User';
    my $ok=eval {$bot->command_registry->handler_for('users',defined($channel)?'public':'private')->($ctx);1};
    return $ok?'':"$@";
}
for my $kind (qw(total levels)) {
    for my $raise (0,1) {
        my (@actual,@expected);
        my @faults=$kind eq 'total'?qw(prepare execute fetch no_row):qw(prepare execute fetch fetch_after_one);
        for my $fault (@faults) {
            my ($bot,$db)=setup_1379($raise);my $before=rows_1379($db);
            $db->{private_fault}="$kind.$fault";
            my $error=invoke_1379($bot,1,1,$raise?undef:'#test');$db->{private_fault}='';
            push @actual,[$fault,$error,dclone(\@wire),dclone($bot->{logger}{entries}),
                $db->{private_finished}//0,$db->{private_prepares}//0,rows_1379($db)];
            my $notice=$kind eq 'total'?'Internal error while reading user statistics.'
                :'Internal error while reading user level statistics.';
            push @expected,[$fault,'',[['notice','Caller',$notice]],
                [[1,"userStats_ctx() $kind read failed."]],
                ($kind eq 'levels'?1:0)+($fault eq 'prepare'?0:1),$kind eq 'total'?1:2,$before];
        }
        is_deeply(\@actual,\@expected,"$kind RaiseError=$raise: no false zero, partial statistics, escaped exception or subsequent query after failure");
    }
}
{
    my ($bot,$db)=setup_1379(1);my $before=rows_1379($db);my @actual;
    for my $channel ('#test',undef) {
        my $error=invoke_1379($bot,1,1,$channel);push @actual,[$error,dclone(\@wire),dclone($bot->{logger}{entries})];
    }
    is_deeply([\@actual,rows_1379($db)],[[map { ['', [['notice','Caller','Users: 4 total — Owner:1, Master:1, Élève:2']], []] } 1..2],$before],
        'healthy public/private commands retain private Unicode output, count ordering and unchanged account rows');
}
{
    my ($bot,$db)=setup_1379(1,1);my $error=invoke_1379($bot,1,1,'#test');
    is_deeply([$error,\@wire,rows_1379($db)],['',[['notice','Caller','Users: 0 total']],[]],
        'a confirmed zero count and empty level breakdown remain successful');
}
{
    my ($bot,$db)=setup_1379(1);my $before=rows_1379($db);my @actual;
    for my $pair ([0,1],[1,0]) {
        my $error=invoke_1379($bot,@$pair,'#test');push @actual,[$error,dclone(\@wire)];
    }
    is_deeply([\@actual,$db->{private_prepares}//0,rows_1379($db)],[[
        ['', [['notice','Caller','You must be logged in to use this command.']]],
        ['', [['notice','Caller','Your level does not allow you to use this command.']]],
    ],0,$before],'authentication and Master guards still prevent all statistics queries');
}
{
    my ($bot,$db)=setup_1379(1);my $before=rows_1379($db);$db->{private_cleanup_failure}=1;
    my $error=invoke_1379($bot,1,1,undef);
    is_deeply([$error,\@wire,$db->{private_finished}//0,rows_1379($db)],
        ['',[['notice','Caller','Users: 4 total — Owner:1, Master:1, Élève:2']],2,$before],
        'cleanup failure alone does not invalidate two confirmed statistics reads');
}
{
    my ($bot,$db)=setup_1379(0);my $before=rows_1379($db);
    $db->{private_fault}='levels.fetch_after_one';$db->{private_cleanup_failure}=1;$bot->{logger}{fail}=1;
    my $error=invoke_1379($bot,1,1,'#test');$db->{private_fault}='';
    is_deeply([$error,\@wire,$db->{private_finished}//0,rows_1379($db)],
        ['',[['notice','Caller','Internal error while reading user level statistics.']],2,$before],
        'cleanup and logger exceptions cannot hide a failed breakdown or publish its first row');
}
is_deeply(\@warnings,[],'account statistics emit no warnings');
done_testing;
