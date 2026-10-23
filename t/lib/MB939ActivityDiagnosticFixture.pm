package MB939ActivityDiagnosticFixture;
use strict;
use warnings;
use utf8;
use MB938ChannelDiagnosticFixture ();
use Mediabot::RSS::Runtime;
use Mediabot::RandomQuote::Runtime;
use Mediabot::Scheduler;
use Mediabot::State::ReadOnly qw(read_json_snapshot);
use File::Temp qw(tempdir);
use File::Find qw(find);
use Fcntl qw(:DEFAULT :flock);
use POSIX qw(mkfifo);
use Time::HiRes ();
use JSON::PP;
use Encode qw(decode FB_CROAK);
{
    package MB939::Conf;
    sub get {return $_[1] eq 'main.RANDOM_QUOTE' ? $_[0]{interval} : undef}
    package MB939::Unavailable;
    sub diagnostic_status {++$_[0]{calls};die "PRIVATE_ERROR_MARKER /private/path\n"}
    package MB939::Untrusted;
    sub diagnostic_status {return $_[0]{result}}
    package MB939::BadScheduler;
    sub task_info {die 'PRIVATE_ERROR_MARKER' if $_[0]{die};return $_[0]{result}}
}
my $json=JSON::PP->new->canonical->utf8;
sub check ($$) {die "$_[1]\n" unless $_[0]}
sub write_file {
    my ($path,$raw)=@_;open my $fh,'>:raw',$path or die $!;
    print {$fh} $raw or die $!;close $fh or die $!;
}
sub populate {
    my ($bot,%args)=@_;my $dir=tempdir(CLEANUP=>1);my $now=time;
    my $loop=IO::Async::Loop->new;$bot->{conf}=bless {interval=>3600},'MB939::Conf';
    my $p=Mediabot::RSS::Pacing->new(path=>"$dir/rss.json",now=>sub{$now});
    my $q=Mediabot::RandomQuote::State->new(path=>"$dir/quote.json",now=>sub{$now});
    $bot->{rss_runtime}=Mediabot::RSS::Runtime->new(bot=>$bot,loop=>$loop,pacing=>$p);
    $bot->{randomquote_runtime}=Mediabot::RandomQuote::Runtime->new(bot=>$bot,loop=>$loop,state=>$q);
    $bot->{scheduler}=Mediabot::Scheduler->new(loop=>$loop);
    unless ($args{empty}) {
        my $channel=$args{channel}//'#test';
        $p->configure($channel,gap=>5,daily=>2);$p->reserve($channel);
        $q->configure($channel,900,3600);
    }
    return ($dir,$p,$q,$now,$loop);
}
sub files {
    my ($dir)=@_;my %files;
    find({no_chdir=>1,wanted=>sub {
        my $name=$File::Find::name;my @s=lstat($name);
        return if -d _;
        $files{$name}=[@s[1,2,7,9]];
        if (-f _) {open my $f,'<:raw',$name or die $!;local $/;push @{$files{$name}},<$f>}
        elsif (-l _) {push @{$files{$name}},readlink($name)}
    }},$dir);
    return $json->encode(\%files);
}
sub run_checks {
    my @out;my $group=sub {my($name,$cb)=@_;my$ok=eval{$cb->();1};push @out,{name=>$name,ok=>$ok?1:0,detail=>$ok?'':"$@"}};
    $group->('absent state stays absent; default interval never fabricates a scheduled attempt',sub {
        my ($b)=MB938ChannelDiagnosticFixture::setup();my($dir,$p,$q)=populate($b,empty=>1);
        my $before=files($dir);my $r=MB938ChannelDiagnosticFixture::collect($b);my $a=$r->{activity};
        check($r->{version}==3 && $a->{rss}{state} eq 'absent' && $a->{rss}{gap}==0,'RSS default observation');
        check($a->{randomquote}{state} eq 'absent' && $a->{randomquote}{interval}==3600
            && !$a->{randomquote}{scheduled} && !exists($a->{randomquote}{next_at}) && !exists($a->{randomquote}{wait}),'fabricated deadline');
        check(files($dir) eq $before,'absent status created files');
        my $missing="$dir/not-created/state.json";check(read_json_snapshot($missing)->{state} eq 'absent' && !-e "$dir/not-created",'reader created directory');
        $b->{conf}{interval}='bad';check(MB938ChannelDiagnosticFixture::collect($b)->{activity}{randomquote}{interval}==10800,'runtime default not reused');
        delete $b->{rss_runtime};check(MB938ChannelDiagnosticFixture::collect($b)->{activity}{rss}{state} eq 'unknown','missing runtime treated as healthy');
    });
    $group->('fresh scoped policies reuse reservation and attempt rules without changing bytes modes or deadlines',sub {
        my ($b)=MB938ChannelDiagnosticFixture::setup();my($dir,$p,$q,$now)=populate($b);
        $p->{now}=sub{$now};$q->{now}=sub{$now};
        $p->configure('#other',gap=>600,daily=>24);$q->configure('#other',7200,3600);
        chmod(0640,"$dir/rss.json.lock","$dir/quote.json.lock") or die $!;
        my $raw=$json->decode(do{open my$f,'<:raw',"$dir/rss.json" or die$!;local$/;<$f>});
        $raw->{private}='PRIVATE_KEY_MARKER';write_file("$dir/rss.json",$json->encode($raw));
        my $before=files($dir);my$r=MB938ChannelDiagnosticFixture::collect($b);my$a=$r->{activity};
        check($a->{rss}{state} eq 'fresh' && $a->{rss}{gap}==5 && $a->{rss}{daily}==2 && $a->{rss}{used}==1 && $a->{rss}{wait}==300,'scoped RSS policy or reservation wait incorrect');
        check($a->{randomquote}{interval}==900 && $a->{randomquote}{next_at}==$now+900 && $a->{randomquote}{pending}==0,'custom quote attempt incorrect');
        check($a->{rss}{file_modified_at}==(stat("$dir/rss.json"))[9] && files($dir) eq $before,'observation modified lock mode or state');
        my$unconfigured=$q->observe('#unconfigured',3600);
        check($unconfigured->{state} eq 'fresh' && $unconfigured->{source} eq 'default'
            && !$unconfigured->{scheduled} && files($dir) eq $before,'missing channel row created or scheduled');
        $a->{rss}{gap}=99;check(MB938ChannelDiagnosticFixture::collect($b)->{activity}{rss}{gap}==5,'report shared mutable state');
        check($json->encode($r)!~/PRIVATE_|other|\.json|\/tmp/,'state contents or path leaked');
        $q->configure('#test',0,3600);$r=MB938ChannelDiagnosticFixture::collect($b);
        check($r->{activity}{randomquote}{interval}==3600 && !$r->{activity}{randomquote}{custom},'default override not distinguished');
        $now+=3600;my$ticket=$q->claim('#test',3600);check($ticket,'ticket setup');
        $before=files($dir);$a=MB938ChannelDiagnosticFixture::collect($b)->{activity};
        check($a->{randomquote}{pending}==1 && files($dir) eq $before,'diagnostic consumed ticket');
        check($q->consume('#test',$ticket->{revision}),'pending ticket lost');
        $p->reserve('#test');my$quota=MB938ChannelDiagnosticFixture::collect($b)->{activity}{rss};
        check($quota->{used}==2 && $quota->{wait}==82800,'rolling quota wait not observed');
    });
    $group->('busy corrupt missing and unsafe state fail independently without repair blocking or raw errors',sub {
        for my $kind (qw(rss quote)) {
            for my $fault (qw(busy invalid_json invalid_schema too_large missing_lock missing_state symlink broken_symlink lock_symlink parent_symlink fifo lock_fifo)) {
                my($b)=MB938ChannelDiagnosticFixture::setup();my($dir)=populate($b);
                my$path="$dir/$kind.json";my$lock;
                if ($fault eq 'busy') {sysopen($lock,"$path.lock",O_RDWR) or die$!;flock($lock,LOCK_EX|LOCK_NB) or die$!}
                elsif ($fault eq 'invalid_json') {write_file($path,'PRIVATE_ERROR_MARKER{')}
                elsif ($fault eq 'invalid_schema') {write_file($path,'{"schema":9,"channels":{}}')}
                elsif ($fault eq 'too_large') {write_file($path,'x'x262145)}
                elsif ($fault eq 'missing_lock') {unlink("$path.lock") or die$!}
                elsif ($fault eq 'missing_state') {unlink($path) or die$!}
                elsif ($fault eq 'symlink') {rename($path,"$path.saved") or die$!;symlink("$path.saved",$path) or die$!}
                elsif ($fault eq 'broken_symlink') {unlink($path) or die$!;symlink("$path.missing",$path) or die$!}
                elsif ($fault eq 'lock_symlink') {rename("$path.lock","$path.saved") or die$!;symlink("$path.saved","$path.lock") or die$!}
                elsif ($fault eq 'parent_symlink') {mkdir "$dir/real" or die$!;symlink("$dir/real","$dir/link") or die$!;my$obj=$kind eq 'rss'?$b->{rss_runtime}{pacing}:$b->{randomquote_runtime}{state};$obj->{path}="$dir/link/state.json"}
                elsif ($fault eq 'fifo') {unlink($path) or die$!;mkfifo($path,0600)==0 or die$!}
                elsif ($fault eq 'lock_fifo') {unlink("$path.lock") or die$!;mkfifo("$path.lock",0600)==0 or die$!}
                my$before=files($dir);my$t=Time::HiRes::time;my$r=MB938ChannelDiagnosticFixture::collect($b);my$a=$r->{activity};
                check(Time::HiRes::time-$t<1,'state read blocked');
                my$key=$kind eq 'rss'?'rss':'randomquote';my$expected=$fault eq 'busy'?'busy':$fault=~/invalid|too_large/?'invalid':'unavailable';
                check($a->{$key}{state} eq $expected,"bad state: $kind $fault");
                my$reason=$fault=~/symlink/?'unsafe_path':$fault=~/fifo/?'not_regular':$fault;
                check($a->{$key}{reason} eq $reason,"bad reason: $kind $fault");
                check($a->{$key eq 'rss'?'randomquote':'rss'}{state} eq 'fresh' && $r->{database} eq 'fresh','fault poisoned independent observations');
                check(files($dir) eq $before,'diagnostic repaired or rewrote state');
                check($json->encode($r)!~/PRIVATE_|\/tmp|\.saved/,'raw error leaked');
                close $lock if $lock;
            }
        }
    });
    $group->('native scheduler registration start tick stop removal and overdue observations never run work',sub {
        my($b)=MB938ChannelDiagnosticFixture::setup();my($dir)=populate($b);my$s=$b->{scheduler};my$calls=0;
        my$r=MB938ChannelDiagnosticFixture::collect($b);check($r->{activity}{tasks}{rss_poll_dispatch}{state} eq 'absent','missing task hidden');
        for my$name(qw(rss_poll_dispatch randomquote_dispatch)) {$s->add(name=>$name,interval=>30,cb=>sub{++$calls},autostart=>0)}
        $r=MB938ChannelDiagnosticFixture::collect($b);check(!$r->{activity}{tasks}{rss_poll_dispatch}{started} && !$calls,'diagnostic started task');
        $s->start('rss_poll_dispatch');$r=MB938ChannelDiagnosticFixture::collect($b);
        check($r->{activity}{tasks}{rss_poll_dispatch}{started} && !$r->{activity}{tasks}{rss_poll_dispatch}{last_tick} && !$calls,'start or never-ticked state incorrect');
        $s->{_tasks}{rss_poll_dispatch}{timer}->invoke_event('on_tick');check($calls==1,'native tick did not run');
        $r=MB938ChannelDiagnosticFixture::collect($b);check($r->{activity}{tasks}{rss_poll_dispatch}{ticks}==1 && $calls==1,'diagnostic ran callback or lost tick');
        my$info=$s->task_info('rss_poll_dispatch');my$activity=Mediabot::Diagnostics::Activity->new(bot=>$b)->collect('#test',$info->{next_run}+7);
        check($activity->{tasks}{rss_poll_dispatch}{overdue_seconds}==7,'overdue wakeup hidden');
        $s->stop('rss_poll_dispatch');$s->remove('randomquote_dispatch');$r=MB938ChannelDiagnosticFixture::collect($b);
        check(!$r->{activity}{tasks}{rss_poll_dispatch}{started} && $r->{activity}{tasks}{randomquote_dispatch}{state} eq 'absent' && $calls==1,'stop/remove observation changed lifecycle');
        delete$b->{scheduler};check(MB938ChannelDiagnosticFixture::collect($b)->{activity}{tasks}{rss_poll_dispatch}{state} eq 'unknown','no scheduler became absent task');
    });
    $group->('extended Telnet and DCC reports remain private UTF-8 bounded and expose no quote text',sub {
        for my$transport(qw(telnet dcc)) {
            my($raw,$other)=MB938ChannelDiagnosticFixture::wire($transport,'#café',sub {populate($_[0],channel=>'#café')});
            my$text=decode('UTF-8',$raw,FB_CROAK);
            check($text=~/RandomQuote: runtime=present; state=fresh/ && $text=~/RSS: runtime=present; state=fresh/ && $text=~/reserved_24h=1/,'activity not rendered on native wire');
            check($text=~/Channel diagnosis #café/ && $text=~/Task\(instance\) rss_poll_dispatch: state=absent/,'UTF-8 or task renderer');
            check($other!~/diagnos|RandomQuote|reserved_24h|café/ && $text!~/PRIVATE_|\.json/,'private output leaked');
            check(length($raw)<6000,'wire byte bound');
        }
    });
    $group->('authorization precedes component access and malformed observations remain bounded unknowns',sub {
        my($b)=MB938ChannelDiagnosticFixture::setup();my$o=bless{calls=>0},'MB939::Unavailable';$b->{rss_runtime}=$o;$b->{randomquote_runtime}=$o;
        MB938ChannelDiagnosticFixture::command($b,level=>2);MB938ChannelDiagnosticFixture::command($b,auth=>0);MB938ChannelDiagnosticFixture::command($b,arg=>'#bad name');
        check(!$o->{calls},'unauthorized component read');
        my$r=MB938ChannelDiagnosticFixture::collect($b);check($r->{activity}{rss}{state} eq 'unavailable' && $r->{database} eq 'fresh','component error aborted report');
        $b->{rss_runtime}=bless {result=>{state=>'fresh',source=>'channel',gap=>'PRIVATE_\nINJECT',daily=>0,used=>0,wait=>0}},'MB939::Untrusted';
        $b->{scheduler}=bless{result=>{name=>'PRIVATE_',mode=>'periodic',started=>1}},'MB939::BadScheduler';
        $r=MB938ChannelDiagnosticFixture::collect($b);check($r->{activity}{rss}{state} eq 'unavailable' && $r->{activity}{tasks}{rss_poll_dispatch}{state} eq 'unavailable','invalid observation accepted');
        my$lines=Mediabot::Diagnostics::Channel->new(bot=>$b)->lines($r);
        check(@$lines<=24 && !grep({length($_)>400 || /[\r\n\x1b]/}@$lines),'unbounded extended report');
        check($json->encode($r)!~/PRIVATE_|INJECT|\/private/,'unapproved component field leaked');
    });
    return \@out;
}
unless (caller) {print $json->encode([@{MB938ChannelDiagnosticFixture::run_checks()},@{run_checks()}])}
1;
