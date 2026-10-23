package MB938ChannelDiagnosticFixture;
use strict;
use warnings;
use utf8;
use DBI;
use DBD::SQLite::Constants qw(SQLITE_OK SQLITE_DENY SQLITE_SELECT SQLITE_READ SQLITE_FUNCTION);
use JSON::PP;
use Encode qw(encode decode FB_CROAK);
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use IO::Async::Loop;
use IO::Async::Stream;
use Future;
use Mediabot::Diagnostics::Channel;
use Mediabot::Partyline;
use Mediabot::AI::ConversationRuntimeState;
{
    package MB938::DBI;our @ISA=('DBI');
    package MB938::DBI::db;our @ISA=('DBI::db');
    sub prepare {
        my ($db,$sql,@rest)=@_;my $p=$db->{private_mb938};
        my $kind=$sql=~/FROM CHANNEL WHERE/?'channel':$sql=~/FROM CHANSET_LIST/?'flags':$sql=~/FROM RSS_FEED/?'rss':'';
        push @{$p->{sql}},$sql if $p;
        $sql='SELECT * FROM mb938_missing_table' if $p && $kind && ($p->{fault}//'') eq "$kind.prepare";
        my $sth=$db->SUPER::prepare($sql,@rest);
        $sth->{private_mb938_kind}=$kind if $sth;
        return $sth;
    }
    package MB938::DBI::st;our @ISA=('DBI::st');
    sub execute {
        my ($sth,@bind)=@_;my $p=$sth->{Database}{private_mb938};my $kind=$sth->{private_mb938_kind}//'';
        push @{$p->{binds}},[$kind,@bind] if $p;
        return $sth->set_err(1,'PRIVATE_ERROR_MARKER') if $p && $kind && ($p->{fault}//'') eq "$kind.execute";
        return $sth->SUPER::execute(@bind);
    }
    sub fetchrow_hashref {
        my $sth=shift;my$p=$sth->{Database}{private_mb938};my$kind=$sth->{private_mb938_kind}//'';
        ++$sth->{private_mb938_fetches};
        return $sth->set_err(1,'PRIVATE_ERROR_MARKER') if $p && $kind && ($p->{fault}//'') eq "$kind.fetch"
            && ($kind eq 'channel' || $sth->{private_mb938_fetches}==2);
        return $sth->SUPER::fetchrow_hashref(@_);
    }
    sub finish {my$sth=shift;my$p=$sth->{Database}{private_mb938};++$p->{finished} if $p;return $sth->SUPER::finish(@_)}
    package MB938::IRC;
    sub is_connected {die 'PRIVATE_ERROR_MARKER' if $_[0]{fail};return $_[0]{connected}}
    package MB938::Owner;
    sub ensure_connected {my$s=shift;++$s->{calls};die 'PRIVATE_ERROR_MARKER' if $s->{fail};return $s->{dbh}}
    package MB938::Buffer;
    sub write {$_[0]{out}.=$_[1];1}
    package MB938::Log;
    sub log {1}
    sub remove_console_hook {1}
    package MB938::Conf;
    sub get_int {$_[2] eq 'default'?$_[3]:0}
    package MB938::Partyline;our @ISA=('Mediabot::Partyline');
    sub _schedule_reverse_dns_lookup {1}
    sub _write_runtime_status {1}
}
my $json=JSON::PP->new->canonical->utf8;
sub check ($$) {die "$_[1]\n" unless $_[0]}
sub setup {
    my(%a)=@_;
    my$db=DBI->connect('dbi:SQLite:dbname=:memory:','','',
        {RootClass=>'MB938::DBI',RaiseError=>$a{raise}//1,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
    $db->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY,name TEXT COLLATE NOCASE,secret TEXT)');
    $db->do('CREATE TABLE CHANSET_LIST(id_chanset_list INTEGER PRIMARY KEY,chanset TEXT)');
    $db->do('CREATE TABLE CHANNEL_SET(id_channel_set INTEGER PRIMARY KEY,id_channel INTEGER,id_chanset_list INTEGER)');
    $db->do('CREATE TABLE RSS_FEED(id_rss_feed INTEGER PRIMARY KEY,id_channel INTEGER,last_error_at TEXT,last_error TEXT)');
    $db->do('INSERT INTO CHANNEL VALUES(7,?,?),(8,?,?)',undef,$a{channel}//'#test','PRIVATE_KEY_MARKER','#other','PRIVATE_KEY_MARKER');
    $db->do(q{INSERT INTO CHANSET_LIST VALUES(1,'AppleMusic'),(2,'AppleMusicFallback'),(3,'Reddit'),(4,'UrlTitle'),(5,'Youtube'),(6,'Games'),(7,'PrivateUnrelatedFlag')});
    $db->do('INSERT INTO CHANNEL_SET VALUES(11,7,2),(12,7,3),(13,8,1),(14,7,7)');
    my$runtime=Mediabot::AI::ConversationRuntimeState->new;
    $runtime->mark_connected;$runtime->mark_joined($a{channel}//'#test');
    my$p={sql=>[],binds=>[],finished=>0,fault=>$a{fault}//''};$db->{private_mb938}=$p;
    my$bot={dbh=>$db,irc=>bless({connected=>1},'MB938::IRC'),wit_runtime_state=>$runtime,
        channels=>{lc($a{channel}//'#test')=>{configured=>1}},logger=>bless({},'MB938::Log'),
        conf=>bless({},'MB938::Conf'),_chanset_cache=>{old=>{val=>1,ts=>123}}};
    return($bot,$db,$p);
}
sub collect {return Mediabot::Diagnostics::Channel->new(bot=>$_[0])->collect($_[1]//'#test')}
sub dumpdb {return $json->encode({map {$_=>$_[0]->selectall_arrayref('SELECT * FROM '.$_.' ORDER BY 1')} qw(CHANNEL CHANSET_LIST CHANNEL_SET RSS_FEED)})}
sub command {
    my($b,%a)=@_;my$s=bless {out=>''},'MB938::Buffer';
    my$pl=bless {bot=>$b,users=>{1=>{authenticated=>exists($a{auth})?$a{auth}:1,level=>exists($a{level})?$a{level}:1}},streams=>{}},'Mediabot::Partyline';
    $pl->_cmd_diagnose($s,1,$a{arg}//'#test');return $s->{out};
}
sub wire {
    my($transport,$channel,$prepare)=@_;my($b,$db,$p)=setup(channel=>$channel);
    $prepare->($b) if $prepare;
    my$loop=IO::Async::Loop->new;
    socketpair(my$server,my$peer,AF_UNIX,SOCK_STREAM,PF_UNSPEC) or die "socketpair: $!";
    my$stream=IO::Async::Stream->new(handle=>$server);my$id=fileno($server);
    my$pl=bless {bot=>$b,loop=>$loop,users=>{},streams=>{},motd=>[]},'MB938::Partyline';
    if ($transport eq 'telnet') {
        no warnings 'redefine';
        local *IO::Async::Loop::listen=sub {my(undef,%args)=@_;$args{on_stream}->($stream);return Future->done};
        $pl->_start_listener;
    }else{$pl->_init_dcc_session($stream,'operator','127.0.0.1')}
    @{$pl->{users}{$id}}{qw(authenticated login level)}=(1,'operator',1);
    my$observer=bless {out=>''},'MB938::Buffer';
    $pl->{users}{9999}={authenticated=>1,login=>'observer',level=>0};$pl->{streams}{9999}=$observer;
    my$input=encode('UTF-8',".diagnose $channel\n");syswrite($peer,$input)==length($input) or die 'native write failed';
    $loop->loop_once(0.005) for 1..12;
    require Fcntl;fcntl($peer,Fcntl::F_SETFL(),fcntl($peer,Fcntl::F_GETFL(),0)|Fcntl::O_NONBLOCK()) or die 'nonblocking failed';
    my$out='';while(sysread($peer,my$chunk,65536)){$out.=$chunk}
    my$other=$observer->{out};delete$pl->{users}{9999};delete$pl->{streams}{9999};
    $pl->_close_session($id);close$peer;
    return($out,$other,$p);
}
sub run_checks {
    my@out;my$group=sub{my($name,$cb)=@_;my$ok=eval{$cb->();1};push@out,{name=>$name,ok=>$ok?1:0,detail=>$ok?'':"$@"}};
    $group->('fresh scoped flags, missing catalogue and AppleMusic dependency have distinct observations',sub {
        my($b,$db,$p)=setup();my$r=collect($b);
        check($r->{database} eq 'fresh' && $r->{flags}{AppleMusicFallback} eq 'on' && $r->{flags}{AppleMusic} eq 'off','activation scope incorrect');
        check($r->{flags}{Reddit} eq 'on' && $r->{flags}{UrlTitle} eq 'off' && $r->{flags}{Gemini} eq 'missing','on/off/missing conflated');
        check(@{$p->{sql}}==3 && $p->{binds}[0][1] eq '#test' && $p->{binds}[1][1]==7 && $p->{binds}[2][1]==7 && $p->{finished}==3,'query scope or cleanup');
        check(join(' ',@{$r->{notes}})=~/prerequisite is off/,'dependency explanation missing');
        my$serialized=$json->encode($r);check($serialized!~/PRIVATE_|PrivateUnrelatedFlag|secret/,'unapproved data leaked');
        $r->{flags}{Reddit}='changed';check(collect($b)->{flags}{Reddit} eq 'on','report retained shared mutable state');
        $db->do('DELETE FROM CHANNEL_SET WHERE id_channel=7 AND id_chanset_list=3');
        check(collect($b)->{flags}{Reddit} eq 'off','fresh read used stale flag cache');
    });
    $group->('runtime observations follow real PART, disconnect and shutdown; cached Channel is not JOIN proof',sub {
        my($b,$db)=setup();my$r=collect($b);check($r->{channel_joined} eq 'yes' && $r->{transport_connected} eq 'yes','healthy runtime missing');
        $b->{wit_runtime_state}->mark_left('#test');$r=collect($b);check($r->{channel_joined} eq 'no','PART hidden by configured Channel');
        $b->{wit_runtime_state}->mark_joined('#test');$b->{irc}{connected}=0;$r=collect($b);
        check(join(' ',@{$r->{notes}})=~/observations disagree/,'inconsistent observations hidden');
        $b->{wit_runtime_state}->mark_disconnected;$r=collect($b);check($r->{runtime_connected} eq 'no' && $r->{channel_joined} eq 'no','disconnect ignored');
        $b->{wit_runtime_state}->mark_shutdown;$r=collect($b);check($r->{runtime_active} eq 'no','shutdown ignored');
        delete$b->{wit_runtime_state};$r=collect($b);check($r->{channel_joined} eq 'unknown','missing runtime fabricated JOIN');
        delete$b->{irc};check(collect($b)->{transport_connected} eq 'unknown','missing transport fabricated connection');
    });
    $group->('database failures, including partial fetches, never become off or disclose raw errors',sub {
        for my$raise(0,1){for my$fault(qw(channel.prepare channel.execute channel.fetch flags.prepare flags.execute flags.fetch)){
            my($b,$db,$p)=setup(raise=>$raise,fault=>$fault);my$r=collect($b);
            check($r->{database} eq 'error' && !grep({$_ ne 'unknown'}values%{$r->{flags}}),"partial result accepted: $raise $fault");
            check($r->{channel_joined} eq 'yes','SQL failure prevented independent runtime observation');
            check(command($b)!~/PRIVATE_|SQLITE|dbi:/,'raw error exposed');
        }}
        my($b,$db,$p)=setup();$b->{db}=bless({fail=>1},'MB938::Owner');my$r=collect($b);
        check($r->{database} eq 'unavailable' && !@{$p->{sql}},'failed connection owner fell back to stale handle');
        delete$b->{db};delete$b->{dbh};check(collect($b)->{database} eq 'unavailable','missing database not explicit');
        ($b,$db,$p)=setup();$db->do("DELETE FROM CHANNEL WHERE id_channel=7");$r=collect($b);
        check($r->{database} eq 'channel_not_found' && $r->{channel_joined} eq 'yes','unknown persisted channel lost runtime distinction');
    });
    $group->('authenticated Master and Owner only; invalid names never reach SQL or diagnostics output',sub {
        for my$spec([0,1,1],[1,1,1],[2,1,0],[-1,1,0],['bad',1,0],[undef,1,0],[0,0,0]) {
            my($level,$auth,$allowed)=@$spec;my($b,$db,$p)=setup();my$s=command($b,level=>$level,auth=>$auth);
            check($allowed?$s=~/Channel diagnosis/:$s=~/Access denied/ && !@{$p->{sql}},'authorization gate incorrect');
        }
        for my$arg('', '#bad name',"#bad\rINJECT",'#bad,other',"#bad\x1b[31m",'#'.('x'x201),"#\xff") {
            my($b,$db,$p)=setup();my$s=command($b,arg=>$arg);
            check($s=~/Usage:/ && !@{$p->{sql}} && $s!~/INJECT/,'invalid channel read or echoed');
        }
    });
    $group->('SQLite authorizer proves SELECT-only reads; caches and caller transaction remain untouched',sub {
        my($b,$db,$p)=setup();my$before=dumpdb($db);my$cache=$json->encode($b->{_chanset_cache});
        $db->sqlite_set_authorizer(sub {my$action=shift;return $action==SQLITE_SELECT || $action==SQLITE_READ || $action==SQLITE_FUNCTION ? SQLITE_OK:SQLITE_DENY});
        my$r=collect($b);check($r->{database} eq 'fresh','read-only authorizer refused diagnostic');
        check(dumpdb($db) eq $before && $json->encode($b->{_chanset_cache}) eq $cache && $db->{AutoCommit},'diagnostic mutated state');
        $db->sqlite_set_authorizer(undef);$db->begin_work;$db->do("INSERT INTO CHANNEL VALUES(9,'#pending','private')");
        check(collect($b)->{database} eq 'fresh' && !$db->{AutoCommit},'caller transaction committed or refused');
        $db->rollback;check(!$db->selectrow_array('SELECT count(*) FROM CHANNEL WHERE id_channel=9'),'rollback lost caller ownership');
    });
    $group->('Telnet and DCC native sockets preserve UTF-8 and keep report and request private',sub {
        for my$transport(qw(telnet dcc)){my($bytes,$other,$p)=wire($transport,'#café');
            my$text=decode('UTF-8',$bytes,FB_CROAK);
            check($text=~/Channel diagnosis #café/ && $text=~/Database: fresh/ && $text=~/joined=yes/,'native transport diagnosis failed');
            check($other!~/diagnose|diagnosis|café/,'diagnostic broadcast to another session');
            check(@{$p->{sql}}==3,'wire command not dispatched exactly once');
            my@lines=split/\r\n/,$text;check(@lines<31 && length($bytes)<6000,'unbounded wire report');
        }
    });
    $group->('help is discoverable and a failed runtime remains unknown with a bounded detached report',sub {
        my($b,$db)=setup();my$s=bless{out=>''},'MB938::Buffer';my$pl=bless{bot=>$b,users=>{},streams=>{}},'Mediabot::Partyline';
        $pl->_cmd_help($s,1,'diagnose');check($s->{out}=~/\.diagnose <#chan>/,'focused help missing');
        $b->{irc}{fail}=1;my$r=collect($b);check($r->{transport_connected} eq 'unknown','transport exception converted to connected');
        my$lines=Mediabot::Diagnostics::Channel->new(bot=>$b)->lines($r);
        check(@$lines<=24 && !grep({length($_)>400 || /[\r\n\x1b]/}@$lines),'report not line-bounded');
        check($json->encode($r)!~/PRIVATE_|DBI|MB938/,'report contains object or error details');
    });
    return\@out;
}
print $json->encode(run_checks()) unless caller;
1;
