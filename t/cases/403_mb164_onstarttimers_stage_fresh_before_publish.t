# t/cases/403_mb164_onstarttimers_stage_fresh_before_publish.t
use strict;
use warnings;

my $case = sub {
    my ($assert) = @_;

    # MB925: native Periodic timers, real event loop and private SQLite.
    # Inject add/start failures before and after their real side effects.
    require JSON::PP;
    my $probe = <<'MB925_NATIVE';
use strict;
use warnings;
use utf8;
use DBI;
use JSON::PP;
use Scalar::Util qw(refaddr weaken);
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Mediabot::DBCommands;
use Mediabot::Mediabot;
use Mediabot::Context;
{
    # Lifecycle controls use the real defining package as their method parent,
    # separately from the public Mediabot wiring exercised below.
    package MB925::TimerOwner; our @ISA=('Mediabot::DBCommands');
    package MB925::Owner; sub has_level {1} sub is_authenticated {1}
    package MB925::Log;
    sub log {my ($s,@v)=@_;push @{$s->{lines}},\@v;1}
    package MB925::IRC;
    sub is_connected {$_[0]{connected}}
    sub write {push @{$_[0]{wire}},$_[1];1}
    package MB925::DBI; our @ISA=('DBI');
    package MB925::DBI::db; our @ISA=('DBI::db');
    sub prepare {
        my ($s,$sql,@rest)=@_;
        my $p=$s->{private_mb925};
        push @{$p->{sql}},$sql if $p;
        my $sth=$s->SUPER::prepare($p && ($p->{read_fault}//'') eq 'prepare' ? 'SELECT * FROM MB1095_ABSENT' : $sql,@rest);
        $sth->{private_mb925}=$p if $sth && $p;
        return $sth;
    }
    package MB925::DBI::st; our @ISA=('DBI::st');
    sub execute {
        my ($s,@bind)=@_;my $p=$s->{private_mb925};
        push @{$p->{binds}},[@bind] if $p;
        return $s->SUPER::execute($p && ($p->{fail_execute} || ($p->{read_fault}//'') eq 'execute') ? ('unexpected-bind') : @bind);
    }
    sub fetchrow_hashref {
        my ($s)=@_;my $p=$s->{private_mb925};
        if ($p && ($p->{read_fault}//'') eq 'fetch'
                && $p->{fetches}++ >= $p->{after}) {
            # DBI records a real statement error; RaiseError chooses whether
            # the production caller receives undef or an exception.
            return $s->set_err(1905, 'MB1095 private fetch failure');
        }
        return $s->SUPER::fetchrow_hashref;
    }
    sub finish {
        my ($s)=@_;my $p=$s->{private_mb925};
        $p->{finishes}++ if $p;
        my $ret=$s->SUPER::finish;
        if ($p && $p->{read_fault}) {
            # Cleanup is allowed to clear DBI's diagnostic before returning.
            $s->set_err(undef,undef);
            die "MB1095 cleanup failure\n" if ($p->{cleanup_read}//'') eq 'throw';
            return undef if ($p->{cleanup_read}//'') eq 'false';
        }
        return $ret;
    }
}
$INC{'MB925/DBI.pm'}=__FILE__;
my $new=IO::Async::Timer::Periodic->can('new');
my $add=IO::Async::Loop->can('add');
my $remove=IO::Async::Loop->can('remove');
my $start=IO::Async::Timer::Periodic->can('start');
my $stop=IO::Async::Timer::Periodic->can('stop');
sub run {
    my (%a)=@_;
    my $loop=IO::Async::Loop->really_new;
    my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',{
        RootClass=>'MB925::DBI',RaiseError=>$a{raise}//0,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
    $db->do('CREATE TABLE TIMERS(id_timers INTEGER PRIMARY KEY,name,duration,command)');
    my @rows=$a{empty} ? () : (
        [1,'alpha',11,"PRIVMSG #test :été alpha"],
        [2,'bravo',12,"PRIVMSG #test :été bravo"],
        [3,'charlie',13,"PRIVMSG #test :été charlie"]);
    push @rows,([4,'',11,'empty name'],[5,'zero',0,'zero'],
        [6,'bad','x','bad'],[7,'none',11,''],[8,'negative',-1,'bad'],
        [9,'missing',undef,'bad']) if $a{invalid};
    push @rows,([10,'cr',11,"PRIVMSG #test :bad\rINJECT"],
        [11,'lf',11,"PRIVMSG #test :bad\nINJECT"],
        [12,'nul',11,"PRIVMSG #test :bad\0INJECT"]) if $a{controls};
    $db->do('INSERT INTO TIMERS VALUES(?,?,?,?)',undef,@$_) for @rows;
    my $bot=bless {loop=>$loop,dbh=>$db,hTimers=>{},
        logger=>bless({lines=>[]},'MB925::Log'),
        irc=>bless({connected=>!$a{disconnected},wire=>[]},'MB925::IRC')},
        $a{public} ? 'Mediabot' : 'MB925::TimerOwner';
    my @old;
    for my $n (1,2) {
        my $t=$new->('IO::Async::Timer::Periodic',interval=>3600,first_interval=>0,
            on_tick=>sub {push @{$bot->{irc}{wire}},"old-$n"});
        $add->($loop,$t);$start->($t);
        $bot->{hTimers}{"old-$n"}=$t;push @old,$t;
    }
    my $old_hash=$bot->{hTimers};
    my @weak;my %labels;my @events;my @construct;my @warnings;
    my ($attempt,$injected)=(0,0);
    my $error="MB925 setup refusal\n";
    my $trace={sql=>[],binds=>[],finishes=>0,fail_execute=>$a{sql_execute}?1:0,
        read_fault=>$a{read_fault}//'',after=>$a{after}//0,fetches=>0,
        cleanup_read=>$a{cleanup_read}//''};
    $db->do('DROP TABLE TIMERS') if $a{sql_prepare};
    $db->{private_mb925}=$trace;
    no warnings qw(redefine once);
    local *IO::Async::Timer::Periodic::new=sub {
        my ($class,%args)=@_;
        push @construct,{interval=>0+$args{interval}};
        # Only the private probe makes the first deadline immediate. The
        # production interval and real loop rescheduling remain unchanged.
        my $t=$new->($class,%args,first_interval=>0);
        my $label='fresh-'.(1+@weak);
        $labels{refaddr($t)}=$label;
        push @weak,$t;weaken($weak[-1]);
        return $t;
    };
    local *IO::Async::Loop::add=sub {
        my ($l,$t)=@_;my $label=$labels{refaddr($t)};
        my $fail=defined($label) && ++$attempt==($a{at}//0);
        push @events,['add',$label//'old'];
        die $error if $fail && ($a{stage}//'') eq 'add-before';
        my $ret=$add->(@_);
        die $error if $fail && ($a{stage}//'') eq 'add-after';
        return $ret;
    };
    local *IO::Async::Timer::Periodic::start=sub {
        my ($t)=@_;my $label=$labels{refaddr($t)};
        my $fail=defined($label) && $attempt==($a{at}//0);
        push @events,['start',$label//'old'];
        die $error if $fail && ($a{stage}//'') eq 'start-before';
        my $ret=$start->(@_);
        die $error if $fail && ($a{stage}//'') eq 'start-after';
        return $ret;
    };
    local *IO::Async::Timer::Periodic::stop=sub {
        my ($t)=@_;my $label=$labels{refaddr($t)};
        push @events,['stop',$label//'old'];
        my $ret=$stop->(@_);
        die "MB925 stop refusal after native stop\n"
            if defined($label) && ($a{cleanup}//'') eq 'stop' && !$injected++;
        return $ret;
    };
    local *IO::Async::Loop::remove=sub {
        my ($l,$t)=@_;my $label=$labels{refaddr($t)};
        push @events,['remove',$label//'old'];
        my $ret=$remove->(@_);
        die "MB925 remove refusal after native removal\n"
            if defined($label) && ($a{cleanup}//'') eq 'remove' && !$injected++;
        return $ret;
    };
    local $SIG{__WARN__}=sub {push @warnings,@_};
    my @notices;my @audit;
    local *Mediabot::botNotice=sub {push @notices,[@_[1,2]];1};
    local *Mediabot::DBCommands::logBot=sub {push @audit,[@_[3,4]];1};
    my $method=$a{entry} eq 'module' ? \&Mediabot::DBCommands::onStartTimers : \&Mediabot::onStartTimers;
    my ($ret,$escaped);
    if ($a{add_command}) {
        my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Reader',channel=>'#test',
            command=>'addtimer',
            args=>['delta',11,'PRIVMSG','#test',":été delta"]);
        $ctx->{user}=bless({},'MB925::Owner');$ctx->{_user_fetched}=1;
        $ret=Mediabot::mbAddTimer_ctx($ctx);
    } else {eval {$ret=$method->($bot);1} or $escaped=1}
    my $tick_ok=eval {$loop->loop_once(0);1};
    my $tick_error=$tick_ok?'':"$@";
    $tick_error=~s/ at [^\n]+ line \d+\.\n\z//;
    my @loop_names=sort map {$labels{refaddr($_)}//'old'} $loop->notifiers;
    my $out={
        return=>$ret,escaped=>$escaped?1:0,
        same_old_hash=>refaddr($old_hash)==refaddr($bot->{hTimers})?1:0,
        old_running=>[map {$_->is_running?1:0} @old],
        old_attached=>[map {defined($_->loop)?1:0} @old],
        fresh=>[map {defined($_)?{alive=>1,running=>$_->is_running?1:0,attached=>defined($_->loop)?1:0}:{alive=>0,running=>0,attached=>0}} @weak],
        loop_names=>\@loop_names,construct=>\@construct,events=>[map {[@$_]} @events],
        registry=>[sort keys %{$bot->{hTimers}}],wire=>[@{$bot->{irc}{wire}}],
        logs=>[@{$bot->{logger}{lines}}],warnings=>\@warnings,trace=>$trace,
        tick_error=>$tick_error,notices=>\@notices,audit=>\@audit};
    $db->{private_mb925}=undef;
    $out->{rows}=$a{sql_prepare}?[]:$db->selectall_arrayref('SELECT * FROM TIMERS ORDER BY id_timers');
    if ($a{recover}) {
        my $recovered=$method->($bot);
        $loop->loop_once(0);
        $out->{recovered}={return=>$recovered,
            registry=>[sort keys %{$bot->{hTimers}}],
            loop_names=>[sort map {$labels{refaddr($_)}//'old'} $loop->notifiers],
            fresh=>[map {defined($_)?1:0} @weak],
            wire=>[@{$bot->{irc}{wire}}]};
    }
    # Explicit teardown outside fault hooks, including cycles retained by the
    # deliberately broken source. Never leave a real notifier behind the probe.
    for my $t ($loop->notifiers) {$stop->($t);$remove->($loop,$t)}
    $bot->{hTimers}={};$db->disconnect;
    return $out;
}
my %out;
require MB1238TimerReload;
MB1238TimerReload::check(sub { push @{$out{reload}}, [$_[0] ? 1 : 0, $_[1]] });
for my $entry (qw(module facade)) {
    for my $stage (qw(add-before add-after start-before start-after)) {
        for my $at (1..3) {
            $out{failure}{$entry}{$stage}{$at}=run(entry=>$entry,stage=>$stage,at=>$at);
        }
    }
    for my $cleanup (qw(stop remove)) {
        $out{cleanup}{$entry}{$cleanup}=run(entry=>$entry,stage=>'start-after',at=>3,cleanup=>$cleanup);
    }
    $out{recovery}{$entry}=run(entry=>$entry,stage=>'start-after',at=>2,recover=>1);
    for my $kind (qw(normal empty invalid disconnected controls sql_prepare sql_execute)) {
        $out{nominal}{$entry}{$kind}=run(entry=>$entry, $kind eq 'normal'?() : ($kind=>1));
    }
}
# MB1095 extends this existing native child, without a new process or delay.
for my $raise (0,1) {
    for my $fault (qw(prepare execute fetch)) {
        for my $after ($fault eq 'fetch' ? (0,1,3) : (0)) {
            for my $cleanup (qw(normal false throw)) {
                my $key=join('/', $raise,$fault,$after,$cleanup);
                $out{reads}{$key}=run(entry=>'facade',public=>1,raise=>$raise,
                    read_fault=>$fault,after=>$after,cleanup_read=>$cleanup,recover=>1);
            }
        }
    }
}
for my $kind (qw(normal empty)) {
    for my $cleanup (qw(normal false throw)) {
        my $key=join('/', $kind,$cleanup);
        $out{read_success}{$key}=run(entry=>'facade',public=>1,
            empty=>$kind eq 'empty'?1:0,read_fault=>'none',cleanup_read=>$cleanup);
    }
}
for my $kind (qw(normal disconnected controls add_command)) {
    $out{public}{$kind}=run(entry=>'facade',public=>1,$kind eq 'normal'?():($kind=>1));
}
{
    # Exercise the actual on_tick event on retained Periodic objects, even
    # after removal. No sleep and no fake implementation of the callback.
    my $loop=IO::Async::Loop->really_new;
    my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',{
        RaiseError=>1,PrintError=>0,AutoCommit=>1});
    $db->do('CREATE TABLE TIMERS(id_timers INTEGER PRIMARY KEY,name,duration,command)');
    $db->do("INSERT INTO TIMERS VALUES(1,'alpha',11,'PRIVMSG #test :original')");
    my $irc=bless {connected=>1,wire=>[]},'MB925::IRC';
    my $bot=bless {loop=>$loop,dbh=>$db,irc=>$irc,hTimers=>{}},'Mediabot';
    my ($attempted,$fail_start);
    no warnings 'redefine';
    local *IO::Async::Timer::Periodic::start=sub {
        my ($t)=@_;
        my $ok=$start->($t);
        $attempted=$t;
        $t->invoke_event('on_tick');
        die "injected start failure\n" if $fail_start;
        return $ok;
    };
    my $initial=$bot->onStartTimers;
    my $original=$bot->{hTimers}{alpha};
    my @before_publish=splice @{$irc->{wire}};
    $original->invoke_event('on_tick');
    my @current=splice @{$irc->{wire}};

    $db->do("UPDATE TIMERS SET command='PRIVMSG #test :replacement'");
    $fail_start=1;
    my $failed=$bot->onStartTimers;
    $attempted->invoke_event('on_tick');
    $original->invoke_event('on_tick');
    my @rollback=splice @{$irc->{wire}};

    $fail_start=0;
    my $reloaded=$bot->onStartTimers;
    my $replacement=$bot->{hTimers}{alpha};
    $original->invoke_event('on_tick');
    $replacement->invoke_event('on_tick');
    my @reload=splice @{$irc->{wire}};

    $bot->_stop_all_runtime_db_timers;
    $replacement->invoke_event('on_tick');
    $out{ownership}={
        returns=>[$initial,$failed,$reloaded],
        wire=>[\@before_publish,\@current,\@rollback,\@reload,[@{$irc->{wire}}]],
        live=>[scalar(keys %{$bot->{hTimers}}),scalar($loop->notifiers)],
    };
    $db->disconnect;
}
print JSON::PP->new->canonical->utf8->encode(\%out);
MB925_NATIVE
    open my $child, '-|', $^X, '-I.', '-It/lib', '-e', $probe
        or do {$assert->(0, "MB925 native child could not start: $!"); return};
    my $raw = do {local $/; <$child>}; close $child;
    my $rc=$?; my $data=eval {JSON::PP::decode_json($raw)};
    $assert->($rc==0 && ref($data) eq 'HASH',
        'MB925 native timer probe completes and returns JSON');
    return unless $rc==0 && ref($data) eq 'HASH';
    $assert->(@$_) for @{$data->{reload}};
    my $same=sub {JSON::PP->new->canonical->encode($_[0]) eq JSON::PP->new->canonical->encode($_[1])};
    my @commands=map {"PRIVMSG #test :\x{e9}t\x{e9} $_\r\n"} qw(alpha bravo charlie);
    my @rows=map {[$_+1,(qw(alpha bravo charlie))[$_],sprintf('%d',$_+11),substr($commands[$_],0,-2)]} 0..2;
    my $failed_state=sub {
        my ($x)=@_;
        return $x->{return}==0 && $x->{same_old_hash}==1
            && $same->($x->{registry},[qw(old-1 old-2)])
            && $same->($x->{old_running},[1,1]) && $same->($x->{old_attached},[1,1])
            && $same->($x->{fresh},[map {{alive=>0,running=>0,attached=>0}} 1..3])
            && $same->($x->{loop_names},[qw(old old)])
            && $same->($x->{wire},[qw(old-1 old-2)])
            && $same->($x->{rows},\@rows)
            && !$x->{tick_error} && !@{$x->{warnings}}
            && $same->($x->{trace}{sql},['SELECT id_timers, name, duration, command FROM TIMERS'])
            && $same->($x->{trace}{binds},[[]]) && $x->{trace}{finishes}==1;
    };
    my @bad; my $count=0;
    for my $entry (qw(module facade)) {
        for my $stage (qw(add-before add-after start-before start-after)) {
            for my $at (1..3) {
                $count++;
                push @bad,"$entry/$stage/$at" unless $failed_state->($data->{failure}{$entry}{$stage}{$at});
            }
        }
    }
    $assert->($count==24 && !@bad,
        'MB925 all 24 partial setups release fresh timers and preserve old registry/ticks'
        . (@bad ? ': '.join(',',@bad) : ''));
    @bad=();
    for my $entry (qw(module facade)) {
        for my $fault (qw(stop remove)) {
            push @bad,"$entry/$fault" unless $failed_state->($data->{cleanup}{$entry}{$fault});
        }
        my $x=$data->{recovery}{$entry};my $r=$x->{recovered};
        push @bad,"$entry/recovery" unless $failed_state->($x) && $r->{return}==3
            && $same->($r->{registry},[qw(alpha bravo charlie)])
            && $same->($r->{loop_names},[qw(fresh-4 fresh-5 fresh-6)])
            && $same->($r->{fresh},[0,0,0,1,1,1])
            && $same->($r->{wire},['old-1','old-2',@commands]);
    }
    $assert->(!@bad,
        'MB925 cleanup exceptions stay contained and the next reload has no ghost timer'
        . (@bad ? ': '.join(',',@bad) : ''));
    @bad=();
    for my $entry (qw(module facade)) {
        for my $kind (qw(normal empty invalid disconnected controls sql_prepare sql_execute)) {
            my $x=$data->{nominal}{$entry}{$kind};
            my $sql_fail=$kind=~/^sql_/;
            my $n=$sql_fail || $kind eq 'empty' ? 0 : $kind eq 'controls' ? 6 : 3;
            my $wire=$sql_fail ? [qw(old-1 old-2)]
                : $kind eq 'disconnected' || $kind eq 'empty' ? [] : \@commands;
            my $registry=$sql_fail ? [qw(old-1 old-2)] : $kind eq 'empty' ? []
                : $kind eq 'controls' ? [qw(alpha bravo charlie cr lf nul)] : [qw(alpha bravo charlie)];
            push @bad,"$entry/$kind" unless $x->{return}==$n && !$x->{tick_error}
                && $x->{same_old_hash}==($sql_fail?1:0)
                && $same->($x->{registry},$registry) && $same->($x->{wire},$wire)
                && $same->($x->{old_running},$sql_fail?[1,1]:[0,0])
                && $same->($x->{old_attached},$sql_fail?[1,1]:[0,0])
                && @{$x->{loop_names}}==($sql_fail?2:$n)
                && $same->($x->{construct},[map {{interval=>$_}} (($kind eq 'controls')?(11,12,13,11,11,11):$n?(11,12,13):())])
                && !@{$x->{warnings}};
        }
    }
    $assert->(!@bad,
        'MB925 nominal reloads, empty/invalid rows, SQL failures and outbound guards retain their contracts'
        . (@bad ? ': '.join(',',@bad) : ''));
    @bad=();
    for my $kind (qw(normal disconnected controls add_command)) {
        my $x=$data->{public}{$kind};
        my $wire=$kind eq 'disconnected' ? []
            : $kind eq 'add_command' ? ['old-1','old-2',"PRIVMSG #test :\x{e9}t\x{e9} delta\r\n"] : \@commands;
        push @bad,$kind unless !$x->{tick_error} && !@{$x->{warnings}}
            && $same->($x->{wire},$wire)
            && $x->{return}==($kind eq 'add_command'?1:$kind eq 'controls'?6:3);
    }
    $assert->(!@bad,
        'MB925 actual Mediabot callbacks resolve the secure writer for reload and authenticated addtimer'
        . (@bad ? ': '.join(',',@bad) : ''));

    my $owned=$data->{ownership};
    my $original="PRIVMSG #test :original\r\n";
    my $replacement="PRIVMSG #test :replacement\r\n";
    $assert->($same->($owned,{returns=>[1,0,1],
            wire=>[[],[$original],[$original],[$replacement],[]],live=>[0,0]}),
        'MB1114 staged, rolled-back and retired native timer callbacks cannot write to IRC'
        . ' (frames by phase: '.join('/',map {scalar @$_} @{$owned->{wire}}).')');

    my (@bad_reads,@bad_recovery,@bad_success);
    for my $key (sort keys %{$data->{reads}}) {
        my $x=$data->{reads}{$key};
        push @bad_reads,$key unless !$x->{escaped} && defined($x->{return})
            && $x->{return}==0 && $x->{same_old_hash}
            && $same->($x->{registry},[qw(old-1 old-2)])
            && $same->($x->{old_running},[1,1]) && $same->($x->{old_attached},[1,1])
            && $same->($x->{loop_names},[qw(old old)])
            && $same->($x->{wire},[qw(old-1 old-2)]) && !@{$x->{events}}
            && !grep {$_->{alive} || $_->{running} || $_->{attached}} @{$x->{fresh}};
        my $r=$x->{recovered};
        push @bad_recovery,$key unless $r->{return}==3
            && $same->($r->{registry},[qw(alpha bravo charlie)])
            && $same->($r->{wire},['old-1','old-2',@commands])
            && @{$r->{loop_names}}==3 && !grep {$_ eq 'old'} @{$r->{loop_names}};
    }
    $assert->(keys(%{$data->{reads}})==30 && !@bad_reads,
        'MB1095 failed and truncated DBI reads preserve the exact live timers with both RaiseError modes'
        . (@bad_reads ? ': '.join(',',@bad_reads) : ''));
    $assert->(!@bad_recovery,
        'MB1095 every failed read can recover on the next native reload without missing or duplicate ticks'
        . (@bad_recovery ? ': '.join(',',@bad_recovery) : ''));
    for my $key (sort keys %{$data->{read_success}}) {
        my $x=$data->{read_success}{$key};my $empty=$key=~/^empty/;
        push @bad_success,$key unless !$x->{escaped}
            && defined($x->{return}) && $x->{return}==($empty?0:3)
            && $same->($x->{old_running},[0,0]) && $same->($x->{old_attached},[0,0])
            && $same->($x->{registry},$empty?[]:[qw(alpha bravo charlie)])
            && $same->($x->{wire},$empty?[]:\@commands)
            && $x->{trace}{finishes}==1;
    }
    $assert->(keys(%{$data->{read_success}})==6 && !@bad_success,
        'MB1095 confirmed complete and empty snapshots publish despite false or throwing cursor cleanup'
        . (@bad_success ? ': '.join(',',@bad_success) : ''));

};

if (caller) { return $case; }

my $tests = 0;
my $fail  = 0;

my $assert = sub {
    my ($ok, $name) = @_;
    $tests++;
    $name = 'unnamed assertion' unless defined $name && $name ne '';

    if ($ok) {
        print "ok $tests - $name\n";
    }
    else {
        print "not ok $tests - $name\n";
        $fail++;
    }
};

$case->($assert);
print "1..$tests\n";
exit($fail ? 1 : 0);
