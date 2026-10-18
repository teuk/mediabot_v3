use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Fcntl qw(:DEFAULT :flock);
use POSIX qw(_exit);
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
done_testing;
