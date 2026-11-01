use strict;
use warnings;
use Test::More;
use DBI;
BEGIN { *CORE::GLOBAL::time = sub { 1_900_000_000 } }
use Mediabot::Partyline;

{
    package LoginFixture::DBI; our @ISA=('DBI');
    package LoginFixture::DBI::db; our @ISA=('DBI::db');
    sub prepare {
        my ($db,$sql,@rest)=@_;
        my $mode=$db->{private_pl_fault}//'';
        my $identity=$sql=~/SELECT u\.id_user/;
        if ($identity) {
            push @{$db->{private_pl_queries}},$sql;
            die "private database detail\n" if $mode eq 'prepare_die';
            if ($mode eq 'prepare_false') {$db->set_err(1105,'private database detail');return undef}
        }
        my $st=$db->SUPER::prepare($sql,@rest);
        $st->{private_pl_fault}=$mode if $st && $identity;
        return $st;
    }
    package LoginFixture::DBI::st; our @ISA=('DBI::st');
    sub execute {
        my ($st,@bind)=@_;my $mode=$st->{private_pl_fault}//'';
        die "private database detail\n" if $mode eq 'execute_die';
        if ($mode eq 'execute_false') {$st->set_err(1105,'private database detail');return undef}
        return $st->SUPER::execute(@bind);
    }
    sub fetchrow_hashref {
        my ($st,@rest)=@_;my $mode=$st->{private_pl_fault}//'';
        die "private database detail\n" if $mode eq 'fetch_die';
        if ($mode eq 'fetch_false') {$st->set_err(1105,'private database detail');return undef}
        my $row=$st->SUPER::fetchrow_hashref(@rest);
        $st->set_err(1105,'private database detail') if $mode eq 'row_error';
        return $row;
    }
    sub finish {
        my ($st)=@_;
        $st->set_err(undef,undef);
        my $ok=$st->SUPER::finish;
        die "private cleanup detail\n" if ($st->{private_pl_fault}//'') eq 'finish_die';
        return $ok;
    }
    package LoginFixture::Auth;
    sub verify_credentials {
        my ($s,@args)=@_;push @{$s->{calls}},\@args;
        die "private verifier detail\n" if $s->{throws};
        return $s->{allow};
    }
    package LoginFixture::Log;
    sub log {my ($s,$level,$msg)=@_;push @{$s->{lines}},$msg;die "private logger detail\n" if $s->{throws};1}
    package LoginFixture::Conf; sub get_int {my ($s,$key,%args)=@_;$args{default}}
    package LoginFixture::Metrics; sub inc {$_[0]{counts}{$_[1]}++;1}
    package LoginFixture::Stream;
    sub write {$_[0]{text}.=$_[1];1}
    sub close_when_empty {$_[0]{closed}++;1}
    package LoginFixture::Timer; sub stop {$_[0]{stopped}++;1}
    package LoginFixture::Loop; sub remove {push @{$_[0]{removed}},$_[1];1}
    package LoginFixture::Party; our @ISA=('Mediabot::Partyline');
    sub _write_runtime_status {$_[0]{published}++;1}
    sub _cmd_whom {$_[0]{whom}++;1}
    sub _broadcast {push @{$_[0]{announced}},$_[1];1}
}
$INC{'LoginFixture/DBI.pm'}=__FILE__;
my @warnings;local $SIG{__WARN__}=sub {push @warnings,@_};
my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',{
    RootClass=>'LoginFixture::DBI',RaiseError=>0,PrintError=>0,AutoCommit=>1});
$db->do('CREATE TABLE USER(id_user INTEGER PRIMARY KEY,nickname TEXT,id_user_level INTEGER)') or die $db->errstr;
$db->do('CREATE TABLE USER_LEVEL(id_user_level INTEGER PRIMARY KEY,level INTEGER,description TEXT)') or die $db->errstr;
$db->do("INSERT INTO USER VALUES(1,'test-user',1)") or die $db->errstr;
$db->do("INSERT INTO USER_LEVEL VALUES(1,0,'Owner')") or die $db->errstr;
my $ip='203.0.113.7';
sub fixture_login {
    my ($role,%args)=@_;
    $db->{private_pl_fault}=undef;
    $db->do('UPDATE USER_LEVEL SET level=?,description=? WHERE id_user_level=1',undef,
        $role,defined($role)&&"$role" eq '1'?'Master':'Owner') or die $db->errstr;
    $db->{private_pl_queries}=[];$db->{private_pl_fault}=$args{fault};
    my $stream=bless {text=>''},'LoginFixture::Stream';
    my $timer=bless {},'LoginFixture::Timer';
    my $p=bless {users=>{7=>{peer_ip=>$ip,peer_host=>$ip,auth_stage=>'password',
        login_failures=>2,authenticated=>0,auth_timeout_timer=>$timer}},streams=>{7=>$stream},
        loop=>bless({removed=>[]},'LoginFixture::Loop'),
        _pl_login_fail_by_ip=>{$ip=>{count=>3,first_ts=>time()}},
        bot=>{dbh=>$db,auth=>bless({allow=>1,calls=>[]},'LoginFixture::Auth'),
            conf=>bless({},'LoginFixture::Conf'),logger=>bless({lines=>[]},'LoginFixture::Log'),
            metrics=>bless({counts=>{}},'LoginFixture::Metrics')}},'LoginFixture::Party';
    return ($p,$stream,$timer);
}
sub login_attempt {
    my ($p,$stream,$name)=@_;
    return eval {$p->_do_login($stream,7,$name//'test-user','<test-password>');1} ? '' : 'escaped exception';
}
sub denial_state {
    my ($p,$s,$error)=@_;
    return [$error,$p->{users}{7}{authenticated}//0,$p->{users}{7}{login_failures},
        $p->{_pl_login_fail_by_ip}{$ip}{count}//0,scalar @{$p->{bot}{auth}{calls}},
        $p->{published}//0,$p->{bot}{metrics}{counts}{mediabot_partyline_logins_total}//0,
        $s->{text}];
}

{
    my ($p,$s,$t)=fixture_login(0);my $error=login_attempt($p,$s);
    is_deeply([$error,$p->{users}{7}{authenticated},$p->{users}{7}{level},
        $p->{users}{7}{auth_stage},$p->{users}{7}{login_failures},exists($p->{_pl_login_fail_by_ip}{$ip})?1:0,
        $p->{bot}{auth}{calls},$t->{stopped},scalar @{$p->{loop}{removed}},$p->{published},$p->{whom},
        $p->{bot}{metrics}{counts}{mediabot_partyline_logins_total},scalar @{$p->{announced}}],
        ['',1,0,undef,0,0,[[1,'test-user','<test-password>']],1,1,1,1,1,1],
        'native Owner login delegates credentials without a password column, clears attempts and publishes exactly once');
}
{
    my ($p,$s,$t)=fixture_login('1',fault=>'finish_die');
    my $error=login_attempt($p,$s);
    is_deeply([$error,$p->{users}{7}{authenticated},$p->{users}{7}{level},$t->{stopped},
        $s->{text}=~/authenticated as Master/?1:0],['',1,1,1,1],
        'native Master login preserves a confirmed read even when statement cleanup throws');
}
my @invalid;
for my $role(-1,'',undef,'owner',2,3) {
    my ($p,$s)=fixture_login($role);my $error=login_attempt($p,$s);
    push @invalid,[$error,$p->{users}{7}{authenticated},$p->{users}{7}{login_failures},
        $p->{_pl_login_fail_by_ip}{$ip}{count},$s->{text}];
}
is_deeply(\@invalid,[map {['',0,3,4,"Access denied: Master level or above required.\r\n"]} 1..6],
    'negative, absent, malformed and unprivileged roles cannot authenticate through numeric coercion');
{
    my ($p,$s)=fixture_login(0);my $error=login_attempt($p,$s,'missing-user');
    is_deeply(denial_state($p,$s,$error),['',0,3,4,0,0,0,"Authentication failed.\r\n"],
        'a confirmed absent user still consumes one session and IP attempt without checking credentials');
}
{
    my ($p,$s)=fixture_login(0);$p->{bot}{auth}{allow}=0;my $error=login_attempt($p,$s);
    is_deeply(denial_state($p,$s,$error),['',0,3,4,1,0,0,"Authentication failed.\r\n"],
        'a genuine credential rejection still consumes exactly one attempt');
}
my @faults;
for my $mode(qw(prepare_false prepare_die execute_false execute_die fetch_false fetch_die row_error)) {
    my ($p,$s)=fixture_login(0,fault=>$mode);my $error=login_attempt($p,$s);
    push @faults,denial_state($p,$s,$error);
}
is_deeply(\@faults,[map {['',0,2,3,0,0,0,"Internal error during authentication.\r\n"]} 1..7],
    'identity read faults stay contained and cannot authenticate or charge either brute-force counter, including err cleared by finish');
{
    my ($p,$s)=fixture_login(0);$p->{bot}{auth}{throws}=1;$p->{bot}{logger}{throws}=1;
    my $error=login_attempt($p,$s);
    is_deeply([denial_state($p,$s,$error),$p->{bot}{logger}{lines}],
        [['',0,2,3,1,0,0,"Internal error during authentication.\r\n"],['Partyline: authentication backend unavailable']],
        'a verifier exception and broken logger produce one bounded reply without private details or authentication side effects');
}
{
    my ($p,$s,$t)=fixture_login(0,fault=>'fetch_false');login_attempt($p,$s);
    $db->{private_pl_fault}=undef;$s->{text}='';my $error=login_attempt($p,$s);
    is_deeply([$error,$p->{users}{7}{authenticated},$p->{users}{7}{login_failures},
        exists($p->{_pl_login_fail_by_ip}{$ip})?1:0,$t->{stopped},\@warnings],['',1,0,0,1,[]],
        'the same session can recover after a backend fault without warnings or a stale lockout');
}
$db->{private_pl_fault}=undef;$db->disconnect;
done_testing;
