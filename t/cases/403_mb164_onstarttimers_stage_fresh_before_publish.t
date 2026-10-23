# t/cases/403_mb164_onstarttimers_stage_fresh_before_publish.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    my $file = File::Spec->catfile($root, 'Mediabot', 'DBCommands.pm');

    open my $fh, '<', $file
        or do { $assert->(0, "cannot open DBCommands.pm: $!"); return; };
    my $src = do { local $/; <$fh> };
    close $fh;

    my ($start) = $src =~ /sub onStartTimers \{(.*?)^sub mbAddTimer_ctx/ms;

    $assert->(defined($start) && length($start) > 0,
        'onStartTimers block extracted');

    $assert->($start =~ /mb164-B1: stage the fresh timer object only/,
        'fetch loop documents fresh timer staging');
    $assert->($start !~ /\$hTimers\{\$name\} = \$timer;\s*\$self->\{loop\}->add\(\$timer\);\s*\$timer->start;/s,
        'old start-inside-fetch-loop pattern is gone');
    $assert->($start =~ /\$hTimers\{\$name\} = \$timer;\s*\$i\+\+;/s,
        'fetch loop only stores timer object and increments count');

    $assert->($start =~ /my \@started_fresh;/,
        'commit path tracks fresh timers that were started');
    $assert->($start =~ /for my \$timer_name \(sort keys %hTimers\)/,
        'commit path starts all staged fresh timers deterministically');
    $assert->($start =~ /\$self->\{loop\}->add\(\$timer\).*?\$timer->start/s,
        'commit path adds and starts fresh timers');
    $assert->($start =~ /unless \(\$ok\).*?for my \$started \(\@started_fresh\).*?\$started->stop if \$started->can\('stop'\).*?\$self->\{loop\}->remove\(\$started\).*?return 0;/s,
        'failed fresh start rolls back already-started fresh timers and keeps old timers alive');

    my $idx_start_fresh = index($start, 'for my $timer_name (sort keys %hTimers)');
    my $idx_stop_old    = index($start, '$self->_stop_all_runtime_db_timers();');
    my $idx_publish     = index($start, '%{$self->{hTimers}} = %hTimers');

    $assert->($idx_start_fresh >= 0 && $idx_stop_old >= 0 && $idx_start_fresh < $idx_stop_old,
        'fresh timers are started before old timers are stopped');
    $assert->($idx_stop_old >= 0 && $idx_publish >= 0 && $idx_stop_old < $idx_publish,
        'old timers are stopped immediately before publishing fresh hash');
    $assert->($start =~ /All fresh timers are alive\. Now stop\/remove the old registered timers/,
        'commit path documents all-fresh-before-stop-old invariant');

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
        my $sth=$s->SUPER::prepare($sql,@rest);
        $sth->{private_mb925}=$p if $sth && $p;
        return $sth;
    }
    package MB925::DBI::st; our @ISA=('DBI::st');
    sub execute {
        my ($s,@bind)=@_;my $p=$s->{private_mb925};
        push @{$p->{binds}},[@bind] if $p;
        return $s->SUPER::execute($p && $p->{fail_execute} ? ('unexpected-bind') : @bind);
    }
    sub finish {
        my ($s)=@_;my $p=$s->{private_mb925};
        $p->{finishes}++ if $p;
        return $s->SUPER::finish;
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
        RootClass=>'MB925::DBI',RaiseError=>0,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
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
    my $trace={sql=>[],binds=>[],finishes=>0,fail_execute=>$a{sql_execute}?1:0};
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
    my $ret;
    if ($a{add_command}) {
        my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Reader',channel=>'#test',
            command=>'addtimer',
            args=>['delta',11,'PRIVMSG','#test',":été delta"]);
        $ctx->{user}=bless({},'MB925::Owner');$ctx->{_user_fetched}=1;
        $ret=Mediabot::mbAddTimer_ctx($ctx);
    } else {$ret=$method->($bot)}
    my $tick_ok=eval {$loop->loop_once(0);1};
    my $tick_error=$tick_ok?'':"$@";
    $tick_error=~s/ at [^\n]+ line \d+\.\n\z//;
    my @loop_names=sort map {$labels{refaddr($_)}//'old'} $loop->notifiers;
    my $out={
        return=>$ret,
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
for my $kind (qw(normal disconnected controls add_command)) {
    $out{public}{$kind}=run(entry=>'facade',public=>1,$kind eq 'normal'?():($kind=>1));
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
