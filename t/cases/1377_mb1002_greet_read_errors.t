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
    package MB1002::DBI; our @ISA = ('DBI');
    package MB1002::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($db,$sql,@rest)=@_;
        my $read=$sql=~/SELECT\s+uc\.greet\s+AS\s+greet/i;
        if ($read) {
            $db->{private_prepares}++;
            return $db->set_err(1,'private greet prepare detail') if ($db->{private_fault}//'') eq 'prepare';
        }
        my $sth=$db->SUPER::prepare($sql,@rest);
        $sth->{private_read}=$read?1:0 if $sth;
        return $sth;
    }
    package MB1002::DBI::st; our @ISA = ('DBI::st');
    sub execute {
        my ($sth,@bind)=@_;
        if ($sth->{private_read}) {
            push @{$sth->{Database}{private_binds}},[@bind];
            return $sth->set_err(1,'private greet execute detail') if ($sth->{Database}{private_fault}//'') eq 'execute';
        }
        return $sth->SUPER::execute(@bind);
    }
    sub fetchrow_hashref {
        my ($sth,@rest)=@_;
        return $sth->set_err(1,'private greet fetch detail')
            if $sth->{private_read} && ($sth->{Database}{private_fault}//'') eq 'fetch';
        return $sth->SUPER::fetchrow_hashref(@rest);
    }
    sub finish {
        my ($sth)=@_;
        if ($sth->{private_read}) {
            $sth->{Database}{private_finished}++;
            $sth->set_err(undef,undef);
            die "private cleanup detail\n" if $sth->{Database}{private_cleanup_failure};
        }
        return $sth->SUPER::finish;
    }
    package MB1002::Log;
    sub log {
        push @{$_[0]{entries}},[@_[1,2]];
        die "private logger detail\n" if $_[0]{fail};
        return 1;
    }
    package MB1002::Message; sub prefix {'Caller!ident@fixture.invalid'}
}
$INC{'MB1002/DBI.pm'}=__FILE__;
my (@wire,@audit,@warnings);
local $SIG{__WARN__}=sub {push @warnings,@_};
no warnings qw(redefine once);
local *Mediabot::UserCommands::botNotice=sub {push @wire,['notice',$_[1],$_[2]];1};
local *Mediabot::UserCommands::botPrivmsg=sub {push @wire,['public',$_[1],$_[2]];1};
local *Mediabot::UserCommands::logBot=sub {push @audit,[@_[2..$#_]];1};
sub setup_1377 {
    my ($raise)=@_;
    my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',
        {RootClass=>'MB1002::DBI',RaiseError=>$raise,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
    $db->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY,name TEXT)');
    $db->do('CREATE TABLE USER(id_user INTEGER PRIMARY KEY,nickname TEXT)');
    $db->do('CREATE TABLE USER_CHANNEL(id_channel INTEGER,id_user INTEGER,greet TEXT)');
    $db->do('INSERT INTO CHANNEL VALUES(7,\'#test\'),(8,\'#else\')');
    $db->do('INSERT INTO USER VALUES(?,?)',undef,@$_) for
        [1,'Friend'],[2,'Zero'],[3,'Empty'],[4,'Null'],[5,'Caller'];
    $db->do('INSERT INTO USER_CHANNEL VALUES(?,?,?)',undef,@$_) for
        [7,1,'Salut élève'],[8,1,'Bonjour ailleurs'],[7,2,'0'],[8,2,'0'],
        [7,3,''],[7,4,undef],[7,5,'Bienvenue Caller'];
    $db->do('PRAGMA query_only = ON');
    my $bot=Mediabot->new({});$bot->{dbh}=$db;
    $bot->{logger}=bless {entries=>[]},'MB1002::Log';
    return ($bot,$db);
}
sub rows_1377 {$_[0]->selectall_arrayref('SELECT * FROM USER_CHANNEL ORDER BY id_channel,id_user')}
sub invoke_1377 {
    my ($bot,$args,$channel)=@_;
    @wire=();@audit=();$bot->{logger}{entries}=[];
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Caller',channel=>$channel,
        command=>'greet',args=>$args,message=>bless({},'MB1002::Message'));
    my $scope=defined($channel)?'public':'private';
    my $ok=eval {$bot->command_registry->handler_for('greet',$scope)->($ctx);1};
    return $ok?'':"$@";
}
for my $raise (0,1) {
    my (@actual,@expected);
    for my $fault (qw(prepare execute fetch)) {
        my ($bot,$db)=setup_1377($raise);my $before=rows_1377($db);
        $db->{private_fault}=$fault;
        my $error=invoke_1377($bot,$raise?['#test','Friend']:['Friend'],$raise?undef:'#test');
        $db->{private_fault}='';
        push @actual,[$fault,$error,dclone(\@wire),dclone(\@audit),
            dclone($bot->{logger}{entries}),$db->{private_finished}//0,rows_1377($db)];
        push @expected,[$fault,'',[[ $raise?'notice':'public',$raise?'Caller':'#test',
            'Database error while fetching greet for Friend on #test.']],[],
            [[1,'userGreet_ctx() database read failed.']],$fault eq 'prepare'?0:1,$before];
    }
    is_deeply(\@actual,\@expected,"RaiseError=$raise: failed greet reads never escape, report absence or audit success");
}
{
    my ($bot,$db)=setup_1377(1);my $before=rows_1377($db);my (@actual,@expected);
    for my $channel ('#test',undef) {
        my $error=invoke_1377($bot,defined($channel)?['Zero']:['#else','Zero'],$channel);
        my $target=defined($channel)?'#test':'#else';
        push @actual,[$error,dclone(\@wire),dclone(\@audit)];
        push @expected,['',[[defined($channel)?'public':'notice',$channel//'Caller',"greet on $target (Zero) 0"]],
            [[$channel,'greet',"Caller!ident\@fixture.invalid greet on Zero for $target"]]];
    }
    is_deeply([\@actual,rows_1377($db)],[\@expected,$before],
        'a stored zero is displayed as a real greet in public and private commands');
}
{
    my ($bot,$db)=setup_1377(1);my $before=rows_1377($db);my @actual;
    for my $args (['Friend!ident@fixture.invalid'],['#else','Friend'],[]) {
        my $error=invoke_1377($bot,$args,'#test');push @actual,[$error,dclone(\@wire),dclone(\@audit)];
    }
    is_deeply([\@actual,$db->{private_binds},rows_1377($db)],[[
        ['', [['public','#test','greet on #test (Friend) Salut élève']], [['#test','greet','Caller!ident@fixture.invalid greet on Friend for #test']]],
        ['', [['public','#test','greet on #else (Friend) Bonjour ailleurs']], [['#test','greet','Caller!ident@fixture.invalid greet on Friend for #else']]],
        ['', [['public','#test','greet on #test (Caller) Bienvenue Caller']], [['#test','greet','Caller!ident@fixture.invalid greet on Caller for #test']]],
    ],[['#test','Friend'],['#else','Friend'],['#test','Caller']],$before],
        'healthy reads retain Unicode, nickname cleanup, explicit/default scope, reply destination and audit');
}
{
    my ($bot,$db)=setup_1377(1);my $before=rows_1377($db);my (@actual,@expected);
    for my $target (qw(Empty Null Missing)) {
        my $error=invoke_1377($bot,[$target],'#test');
        push @actual,[$error,dclone(\@wire),dclone(\@audit)];
        push @expected,['',[['public','#test',"No greet for $target on #test"]],
            [['#test','greet',"Caller!ident\@fixture.invalid greet on $target for #test"]]];
    }
    is_deeply([\@actual,rows_1377($db)],[\@expected,$before],
        'confirmed empty, NULL and absent rows retain the existing no-greet result and audit');
}
{
    my ($bot,$db)=setup_1377(1);my $before=rows_1377($db);my (@actual,@expected);
    $db->{private_cleanup_failure}=1;
    for my $target (qw(Friend Missing)) {
        my $error=invoke_1377($bot,[$target],'#test');
        push @actual,[$error,dclone(\@wire),dclone(\@audit)];
        my $text=$target eq 'Friend'?'greet on #test (Friend) Salut élève':'No greet for Missing on #test';
        push @expected,['',[['public','#test',$text]],
            [['#test','greet',"Caller!ident\@fixture.invalid greet on $target for #test"]]];
    }
    is_deeply([\@actual,rows_1377($db)],[\@expected,$before],
        'cleanup failure alone cannot discard a confirmed greeting or confirmed absence');
}
{
    my ($bot,$db)=setup_1377(0);my $before=rows_1377($db);
    $db->{private_fault}='fetch';$db->{private_cleanup_failure}=1;$bot->{logger}{fail}=1;
    my $error=invoke_1377($bot,['#test','Friend'],undef);$db->{private_fault}='';
    is_deeply([$error,\@wire,\@audit,$db->{private_finished}//0,rows_1377($db)],
        ['', [['notice','Caller','Database error while fetching greet for Friend on #test.']],[],1,$before],
        'cleanup and failure-logger exceptions cannot hide the original failed read');
}
{
    my ($bot,$db)=setup_1377(1);my $before=rows_1377($db);my @actual;
    push @actual,[invoke_1377($bot,['Friend'],undef),dclone(\@wire),dclone(\@audit)];
    push @actual,[invoke_1377($bot,['Friend'],'else'),dclone(\@wire),dclone(\@audit)];
    is_deeply([\@actual,$db->{private_prepares}//0,rows_1377($db)],[[
        ['', [['notice','Caller','Syntax (in private): greet #channel <nick>']],[]],
        ['', [['notice','Caller','Syntax: greet [#channel] <nick>']],[]],
    ],0,$before],'invalid channel scope retains syntax notices and never opens a greet query');
}
is_deeply(\@warnings,[],'greet reads emit no warnings');
done_testing;
