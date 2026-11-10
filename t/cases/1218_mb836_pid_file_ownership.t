use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Fcntl qw(:DEFAULT :flock);
use POSIX qw(_exit);
use Text::Balanced qw(extract_codeblock);
use Mediabot::ProcessLock;

my $dir=tempdir(CLEANUP=>1);
my $path="$dir/bot.pid";
sub read_file { my ($p)=@_;open my $fh,'<:raw',$p or die $!;local $/;return <$fh> }
sub write_file { my ($p,$value)=@_;open my $fh,'>:raw',$p or die $!;
    print {$fh} $value;close $fh or die $! }
my $old=Mediabot::ProcessLock->new(path=>$path);
ok($old->acquire,'initial owner acquires the PID file');
rename $path,"$dir/old.pid" or die $!;
my $new=Mediabot::ProcessLock->new(path=>$path);
ok($new->acquire,'replacement owns a separate file at the same path');
my $replacement=read_file($path);
ok(!$old->release,'old owner reports changed path instead of deleting the replacement');
ok(-f $path,'replacement PID file survives old-owner release');
is((-f $path?read_file($path):''),$replacement,'replacement contents remain exact even with identical PID values');
like($old->error,qr/replacement retained/,'changed-path diagnostic is explicit');
my $pid=fork();die $! unless defined $pid;
if (!$pid) {
    close $new->{fh};
    my $third=Mediabot::ProcessLock->new(path=>$path);
    _exit($third->acquire?1:0);
}
waitpid($pid,0);
is($? >> 8,0,'third process is still refused after old-owner cleanup');
ok($new->release,'replacement can release its own file normally');
ok(!-e $path,'normal replacement release removes its own path');
ok($old->release,'releasing an already closed old handle is idempotent');

my $gone=Mediabot::ProcessLock->new(path=>$path);ok($gone->acquire,'missing-path fixture acquires');
unlink $path or die $!;
ok($gone->release,'already removed owned path does not prevent releasing the descriptor');

my $target="$dir/target.pid";write_file($target,'');
symlink $target,$path or die $!;
my $alias=Mediabot::ProcessLock->new(path=>$path);
ok($alias->acquire,'existing stable symbolic PID alias remains supported');
ok($alias->release,'stable alias releases normally');
ok(!-l $path && -f $target,'normal alias release removes its alias and preserves its target');
write_file($target,'');symlink $target,$path or die $!;
my $retargeted=Mediabot::ProcessLock->new(path=>$path);ok($retargeted->acquire,'retarget fixture acquires');
rename $path,"$dir/previous-alias" or die $!;
symlink $target,$path or die $!;
ok(!$retargeted->release,'a new alias to even the same target is a distinct directory entry');
ok(-l $path,'replacement alias survives cleanup');
unlink $path if -l $path;

# Replacing the path while acquire is preparing must not claim the new file
# or chmod it through the pathname. Writes stay bound to the opened descriptor.
my $reader=\&Mediabot::ProcessLock::_read_pid_from_fh;
{
    no warnings qw(redefine once);
    local *Mediabot::ProcessLock::_read_pid_from_fh=sub{
        my $value=$reader->(@_);
        rename $path,"$dir/acquire-old.pid" or die $!;
        write_file($path,"replacement marker\n");chmod 0600,$path or die $!;
        return $value;
    };
    my $raced=Mediabot::ProcessLock->new(path=>$path);
    ok(!$raced->acquire,'observed replacement during acquire is refused');
    is(read_file($path),"replacement marker\n",'failed acquire preserves replacement bytes');
    is((stat($path))[2]&0777,0600,'failed acquire preserves replacement mode');
    ok($raced->release,'failed acquire leaves no owned descriptor');
}

# Exercise the native bot entry point without loading the entire runtime.
my $core=read_file('Mediabot/Mediabot.pm');
$core =~ /sub acquirePidFile\s*(\{)/g or die 'acquirePidFile missing';
my ($body)=extract_codeblock(substr($core,$-[1]));
die 'acquirePidFile incomplete' unless $body;
eval "package PIDFork::Bot; sub acquirePidFile $body; 1" or die $@;
{
    package PIDFork::Log;
    sub log {push @{$_[0]{lines}},$_[2]}
}
sub child_result {
    my ($code)=@_;
    my $child=fork();die $! unless defined $child;
    if (!$child) {
        my $result=eval {$code->()};
        _exit($@ ? 127 : $result);
    }
    local $SIG{ALRM}=sub {kill 'KILL',$child;waitpid($child,0);die 'PID child timed out'};
    alarm 5;
    waitpid($child,0)==$child or die $!;
    my $status=$?;
    alarm 0;
    return $status;
}

unlink $path or die $!;
my $parent=Mediabot::ProcessLock->new(path=>$path);
$parent->acquire or die $parent->error;
my $original=read_file($path);
my @identity=stat($path);
is(child_result(sub {$parent->release ? 0:1}),0,'child cleanup closes its inherited descriptor successfully');
ok(-f $path,'child cleanup keeps the live parent PID path');
is((-f $path?read_file($path):''),$original,'child cleanup leaves parent PID bytes intact');
is_deeply([(-f $path?stat($path):())[0,1]],[@identity[0,1]],'child cleanup preserves the locked directory entry');
is(child_result(sub {
    my $other=Mediabot::ProcessLock->new(path=>$path);
    my $acquired=$other->acquire;
    $other->release if $acquired;
    return $acquired?1:0;
}),0,'a fresh process remains blocked after child cleanup');
ok($parent->release && !-e $path,'parent alone can remove its own PID path');

my $held=Mediabot::ProcessLock->new(path=>$path);
$held->acquire or die $held->error;
my $logger=bless {lines=>[]},'PIDFork::Log';
my $bot=bless {pid_file_lock=>$held,logger=>$logger},'PIDFork::Bot';
ok($bot->acquirePidFile,'native acquire remains idempotent in the owning process');
is(child_result(sub {
    return 1 if $bot->acquirePidFile;
    return 2 unless @{$logger->{lines}}==1 && $logger->{lines}[0] =~ /another process/;
    return 3 if $held->{fh};
    return 4 if $held->acquire;
    return 0;
}),0,'native bot acquire refuses the inherited object, reports ownership and drops only the child handle');
ok($held->release && !-e $path,'refused child acquire leaves the owner able to release normally');

my $unheld=Mediabot::ProcessLock->new(path=>$path);
is(child_result(sub {return $unheld->acquire?1:0}),0,'an object made before fork cannot write the parent PID from the child');
ok(!-e $path,'refused inherited acquire does not create a PID file');
unlink $path if -f $path;
is(child_result(sub {
    my $own=Mediabot::ProcessLock->new(path=>$path);
    return 1 unless $own->acquire;
    return 2 unless read_file($path) eq "$$\n";
    return $own->release && !-e $path ? 0:3;
}),0,'a new child-owned object can acquire and release with its own PID');


# MB1194: failed PID reads must never masquerade as an empty file.
my $probe = <<'PROBE';
use strict; use warnings; use Errno qw(EINTR EIO); use JSON::PP;
our ($mode,$reads);
BEGIN { *CORE::GLOBAL::sysread = sub {
    ++$reads;
    if ($reads == 1) { $! = $mode eq 'interrupt' ? EINTR : EIO; return undef; }
    return CORE::sysread($_[0],$_[1],$_[2]);
}; }
use Mediabot::ProcessLock;
($mode,$reads)=($ARGV[1],0);
my $lock=Mediabot::ProcessLock->new(path=>$ARGV[0]);
my $ok=$lock->acquire;
print JSON::PP->new->encode({ok=>$ok?1:0,error=>$lock->error,reads=>$reads});
$lock->release if $ok;
PROBE
require JSON::PP;
for my $mode (qw(interrupt io)) {
    my $probe_path="$dir/read-$mode.pid";
    write_file($probe_path,"$$\n");
    open my $child,'-|',$^X,'-I.','-e',$probe,$probe_path,$mode or die $!;
    my $raw=do {local $/;<$child>};close $child;
    is($?,0,"$mode: PID read probe completes");
    my $result=JSON::PP->new->decode($raw);
    ok(!$result->{ok},"$mode: child cannot acquire over a live parent PID");
    like($result->{error}//'', $mode eq 'interrupt' ? qr/live process/ : qr/cannot read PID/,
        "$mode: refusal retains a useful diagnostic");
    is($result->{reads},$mode eq 'interrupt' ? 2:1,"$mode: retry only interrupted reads");
    is(-f $probe_path?read_file($probe_path):'',"$$\n","$mode: live parent PID remains untouched");
}
done_testing;
