use strict;
use warnings;
use JSON::PP;
use Time::HiRes qw(time sleep);
use POSIX qw(WNOHANG);
use Mediabot::Achievements;
{
    package MB1220::RejectLoop;
    sub add {die 'unexpected notifier add'}
    sub remove {die 'unexpected notifier remove'}
    sub watch_process {$_[0]{pid}=$_[1];die "watch rejected\n"}
    package MB1220::Log;
    sub log {push @{$_[0]{lines}},$_[2]}
}
local $SIG{CHLD}='DEFAULT';
my $loop=bless {},'MB1220::RejectLoop';
my $log=bless {},'MB1220::Log';
my $a=bless {bot=>{loop=>$loop},logger=>$log},'Mediabot::Achievements';
my @results;
my $start=time;
my $returned=$a->_spawn_check_worker({nick=>'Probe',channel=>'#offline'},sub {push @results,$_[0]});
my $elapsed=time-$start;
# Observe the postcondition before fixture cleanup: a successful reap means ECHILD.
my $pid=$loop->{pid} or die 'worker was not forked';
my $seen=waitpid($pid,WNOHANG);
my $no_child=$seen==-1 && $!{ECHILD} ? 1:0;
# The baseline leaks ownership; always clean our own child even on a failed test.
if ($seen==0) {kill 'KILL',$pid;while(waitpid($pid,0)==-1 && $!{EINTR}) {}}
print encode_json({returned=>$returned,count=>scalar(@results),result=>$results[0],
    reaped=>$no_child,elapsed=>$elapsed,registered=>exists($a->{_worker_process})?1:0});
