use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use Storable qw(dclone);
use Encode qw(encode);
use Mediabot::Mediabot;
use Mediabot::Context;
binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
{
    package MB1005::DBI; our @ISA=('DBI');
    package MB1005::DBI::db; our @ISA=('DBI::db');
    sub prepare {
        my ($db,$sql,@rest)=@_;
        my $kind=$sql=~/END AS has_password/?'profile'
            :$sql=~/SELECT hostmask FROM USER_HOSTMASK/?'masks':'';
        if ($kind) {
            $db->{private_prepares}++;
            return $db->set_err(1,'private profile prepare detail')
                if ($db->{private_fault}//'') eq "$kind.prepare";
        }
        my $sth=$db->SUPER::prepare($sql,@rest);
        $sth->{private_kind}=$kind if $sth;
        return $sth;
    }
    package MB1005::DBI::st; our @ISA=('DBI::st');
    sub execute {
        my ($sth,@bind)=@_;
        $sth->{private_fetched}=0;
        return $sth->set_err(1,'private profile execute detail')
            if $sth->{private_kind} && ($sth->{Database}{private_fault}//'') eq "$sth->{private_kind}.execute";
        return $sth->SUPER::execute(@bind);
    }
    sub fetchrow_hashref {
        my ($sth,@rest)=@_;
        my $kind=$sth->{private_kind}//'';
        my $fault=$sth->{Database}{private_fault}//'';
        if ($kind && ($fault eq "$kind.fetch"
                || ($fault eq "$kind.fetch_after_one" && $sth->{private_fetched}))) {
            return $sth->set_err(1,'private profile fetch detail');
        }
        my $row=$sth->SUPER::fetchrow_hashref(@rest);
        $sth->{private_fetched}++ if $row;
        return $row;
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
    package MB1005::Log;
    sub log {
        push @{$_[0]{entries}},[@_[1,2]];
        die "private logger detail\n" if $_[0]{fail};
        return 1;
    }
    package MB1005::User;
    sub is_authenticated {$_[0]{auth}}
    sub has_level {$_[1] eq 'Administrator' && $_[0]{admin}}
}
$INC{'MB1005/DBI.pm'}=__FILE__;
my (@wire,@warnings);
local $SIG{__WARN__}=sub {push @warnings,@_};
no warnings qw(redefine once);
local *Mediabot::botNotice=sub {push @wire,['notice',$_[1],$_[2]];1};
local *Mediabot::botPrivmsg=sub {push @wire,['public',$_[1],$_[2]];1};
local *Mediabot::UserCommands::botNotice=sub {push @wire,['notice',$_[1],$_[2]];1};
local *Mediabot::UserCommands::botPrivmsg=sub {push @wire,['public',$_[1],$_[2]];1};
sub setup_1380 {
    my ($raise,$masks)=@_; $masks //= ['*!élève@one','*!user@two','*!user@three'];
    my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',
        {RootClass=>'MB1005::DBI',RaiseError=>$raise,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
    $db->do('CREATE TABLE USER_LEVEL(id_user_level INTEGER PRIMARY KEY,description TEXT,level INTEGER)');
    $db->do('CREATE TABLE USER(id_user INTEGER PRIMARY KEY,nickname TEXT,id_user_level INTEGER,creation_date TEXT,last_login TEXT,password TEXT,info1 TEXT,info2 TEXT,auth INTEGER,username TEXT)');
    $db->do('CREATE TABLE USER_HOSTMASK(id_user_hostmask INTEGER PRIMARY KEY,id_user INTEGER,hostmask TEXT)');
    $db->do('INSERT INTO USER_LEVEL VALUES(1,?,10)',undef,'Administrateur');
    $db->do('INSERT INTO USER VALUES(1,?,1,?,?,?,?,?,?,?)',undef,
        'Zoé','2026-10-01',undef,'private-stored-value','équipe','0',1,'zoe_login');
    my $i=0;
    $db->do('INSERT INTO USER_HOSTMASK VALUES(?,1,?)',undef,++$i,$_) for @$masks;
    $db->do('PRAGMA query_only = ON');
    my $bot=Mediabot->new({}); $bot->{dbh}=$db;
    $bot->{logger}=bless {entries=>[]},'MB1005::Log';
    return ($bot,$db);
}
sub rows_1380 {
    return [map {$_[0]->selectall_arrayref("SELECT * FROM $_ ORDER BY 1")} qw(USER USER_HOSTMASK)];
}
sub invoke_1380 {
    my ($bot,$channel,$target,$auth,$admin)=@_;
    @wire=(); $bot->{logger}{entries}=[];
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Caller',channel=>$channel,
        command=>'userinfo',args=>[defined($target)?$target:'Zoé']);
    $ctx->{_user_fetched}=1;
    $ctx->{user}=bless {auth=>$auth//1,admin=>$admin//1},'MB1005::User';
    my $ok=eval {$bot->command_registry->handler_for('userinfo',defined($channel)?'public':'private')->($ctx);1};
    return $ok?'':"$@";
}
my @profile=(['notice','Caller','[1] Zoé | Level: Administrateur | Auth: 1 | Pass: yes | Username: zoe_login'],
    ['notice','Caller','Created: 2026-10-01 | Last login: never | Info1: équipe | Info2: 0']);
my @masks=(['notice','Caller','Hostmasks: 3 shown, max 20'],
    ['notice','Caller','userinfo-masks[01]: *!élève@one | *!user@two'],
    ['notice','Caller','userinfo-masks[02]: *!user@three']);
for my $kind (qw(profile masks)) {
    for my $raise (0,1) {
        my (@actual,@expected);
        my @faults=$kind eq 'profile'?qw(prepare execute fetch):qw(prepare execute fetch fetch_after_one);
        for my $fault (@faults) {
            my ($bot,$db)=setup_1380($raise); my $before=rows_1380($db);
            $db->{private_fault}="$kind.$fault";
            my $error=invoke_1380($bot,$raise?undef:'#test'); $db->{private_fault}='';
            push @actual,[$fault,$error,dclone(\@wire),dclone($bot->{logger}{entries}),
                $db->{private_finished}//0,$db->{private_prepares}//0,rows_1380($db)];
            my @reply=$kind eq 'profile'?(['notice','Caller','Database error while fetching user information.'])
                :(@profile,['notice','Caller','Hostmasks: unavailable (database error).']);
            push @expected,[$fault,'',\@reply,[[1,"userInfo_ctx() $kind read failed."]],
                ($kind eq 'masks'?1:0)+($fault eq 'prepare'?0:1),$kind eq 'profile'?1:2,$before];
        }
        is_deeply(\@actual,\@expected,"$kind RaiseError=$raise: failures stay private and cannot become unknown users, missing masks or partial lists");
    }
}
{
    my ($bot,$db)=setup_1380(1); my $before=rows_1380($db); my @actual;
    for my $channel ('#test',undef) {
        my $error=invoke_1380($bot,$channel); push @actual,[$error,dclone(\@wire),dclone($bot->{logger}{entries})];
    }
    is_deeply([\@actual,rows_1380($db)],[[map {['',[@profile,@masks],[]]} 1..2],$before],
        'healthy public/private registry calls preserve private fields, password presence only, Unicode and mask order');
}
{
    my ($bot,$db)=setup_1380(1,[]); my $before=rows_1380($db); my @actual;
    for my $target ('Zoé','Nobody') {
        my $error=invoke_1380($bot,undef,$target); push @actual,[$error,dclone(\@wire)];
    }
    is_deeply([\@actual,$db->{private_prepares},rows_1380($db)],[[
        ['',[@profile,['notice','Caller','Hostmasks: none']]],
        ['',[['notice','Caller','Unknown user Nobody']]],
    ],3,$before],'confirmed missing account and empty mask list retain their distinct responses');
}
{
    my @input=('*!'.('x'x400).'@long',map {"*!user\@host$_"} 2..21);
    my ($bot,$db)=setup_1380(1,\@input); my $before=rows_1380($db);
    my $error=invoke_1380($bot,'#test');
    my @detail=@wire[3..$#wire];
    is_deeply([$error,$wire[2],scalar(@detail),
        scalar(grep {length(encode('UTF-8',$_->[2]))>360} @detail),
        scalar(grep {$_->[2]=~/host21/} @detail),$detail[-1],rows_1380($db)],
        ['',['notice','Caller','Hostmasks: 20 shown, max 20'],10,0,0,
         ['notice','Caller','userinfo-masks[10]: *!user@host19 | *!user@host20'],$before],
        'the existing 20-mask limit, two per line, numbering and long-line truncation remain');
}
{
    my ($bot,$db)=setup_1380(1); my $before=rows_1380($db); my @actual;
    for my $case ([0,1,'Zoé'],[1,0,'Zoé'],[1,1,'']) {
        my ($auth,$admin,$target)=@$case;
        my $error=invoke_1380($bot,'#test',$target,$auth,$admin);
        push @actual,[$error,dclone(\@wire)];
    }
    is_deeply([\@actual,$db->{private_prepares}//0,rows_1380($db)],[[
        ['',[['notice','Caller','You must be logged in to use this command.']]],
        ['',[['notice','Caller','Your level does not allow you to use this command.']]],
        ['',[['notice','Caller','Syntax: userinfo <username>']]],
    ],0,$before],'authentication, Administrator and syntax guards prevent all profile queries');
}
{
    my ($bot,$db)=setup_1380(1); my $before=rows_1380($db); $db->{private_cleanup_failure}=1;
    my $error=invoke_1380($bot,undef);
    is_deeply([$error,\@wire,$db->{private_finished}//0,rows_1380($db)],
        ['',[@profile,@masks],2,$before],
        'cleanup exceptions alone do not discard confirmed profile and mask reads');
}
{
    my ($bot,$db)=setup_1380(0); my $before=rows_1380($db);
    $db->{private_fault}='masks.fetch_after_one'; $db->{private_cleanup_failure}=1; $bot->{logger}{fail}=1;
    my $error=invoke_1380($bot,'#test'); $db->{private_fault}='';
    is_deeply([$error,\@wire,$db->{private_finished}//0,rows_1380($db)],
        ['',[@profile,['notice','Caller','Hostmasks: unavailable (database error).']],2,$before],
        'cleanup and logger failures cannot hide an interrupted mask read or expose its first row');
}
is_deeply(\@warnings,[],'userinfo reads emit no warnings');
done_testing;
