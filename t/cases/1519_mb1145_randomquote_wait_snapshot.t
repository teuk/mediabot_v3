use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Mediabot::RandomQuote::State;

my $dir=tempdir(CLEANUP=>1);
my $path="$dir/state.json";
my ($now,$step,$reads)=(1000000,0,0);
my $state=Mediabot::RandomQuote::State->new(path=>$path,now=>sub {
    ++$reads; my $value=$now; $now+=$step; return $value;
});
$state->configure('#test',900,10800);
my $deadline=$state->status('#test',10800)->{next_at};
open my $fh,'<:raw',$path or die $!;
my $original=do {local $/;<$fh>};close $fh;
for my $method (qw(status observe)) {
    for my $offset (-100,-1,0,1,100) {
        ($now,$step,$reads)=($deadline+$offset,2,0);
        my $result=$state->$method('#test',10800);
        is($result->{wait},$offset<0 ? -$offset : 0,"$method wait uses one observation of time");
        is($reads,1,"$method reads the clock once for an existing schedule");
        cmp_ok($result->{wait},'>=',0,"$method never returns a negative wait");
        is($result->{next_at},$deadline,"$method preserves the scheduled deadline");
    }
    ($now,$step,$reads)=($deadline-1,2,0);
    my $result=$state->$method('#unknown',10800);
    is($reads,0,"$method needs no clock for an unscheduled channel");
    is($result->{interval},10800,"$method preserves default interval");
}
open $fh,'<:raw',$path or die $!;
my $after=do {local $/;<$fh>};close $fh;
is($after,$original,'status and observation do not rewrite persistent state');

# MB1191: inject read errors in a separate interpreter, never in the runner.
my $probe_code = <<'PROBE';
use strict;
use warnings;
use Errno qw(EINTR EIO EAGAIN);
our ($mode, $calls);
BEGIN {
    *CORE::GLOBAL::sysread = sub {
        ++$calls;
        if (($mode eq 'interrupt' && ($calls == 1 || $calls == 3))
            || ($mode eq 'io' && $calls == 2) || $mode eq 'again') {
            $! = $mode eq 'interrupt' ? EINTR : $mode eq 'io' ? EIO : EAGAIN;
            return undef;
        }
        my $size = $_[2];
        $size = 7 if ($mode eq 'interrupt' && $calls == 2) || ($mode eq 'io' && $calls == 1);
        return CORE::sysread($_[0], $_[1], $size);
    };
}
use Mediabot::State::ReadOnly qw(read_json_snapshot);
use JSON::PP;
($mode, $calls) = ($ARGV[1], 0);
local $SIG{ALRM} = sub { die "read retry did not terminate\n" };
alarm 5;
my $result = read_json_snapshot($ARGV[0]);
alarm 0;
print JSON::PP->new->canonical->encode({result=>$result,calls=>$calls});
PROBE
require JSON::PP;
for my $mode (qw(normal interrupt io again)) {
    open my $probe, '-|', $^X, '-I.', '-e', $probe_code, $path, $mode or die $!;
    my $raw = do {local $/; <$probe>};
    close $probe;
    is($?,0,"$mode: isolated read probe terminates successfully");
    my $data = JSON::PP->new->decode($raw);
    if ($mode eq 'normal' || $mode eq 'interrupt') {
        is($data->{result}{state},'fresh',"$mode: valid state remains observable");
        is_deeply($data->{result}{document},JSON::PP->new->decode($original),
            "$mode: complete document survives partial and interrupted reads");
        is($data->{calls},$mode eq 'interrupt' ? 5 : 2,"$mode: expected read and retry count");
    } else {
        is($data->{result}{state},'unavailable',"$mode: genuine read failure remains unavailable");
        is($data->{result}{reason},'unreadable',"$mode: existing diagnostic is preserved");
        is($data->{calls},$mode eq 'io' ? 2 : 1,"$mode: non-EINTR errors are not retried");
    }
}
open $fh,'<:raw',$path or die $!;
is(do {local $/;<$fh>},$original,'read retries and failures never rewrite the state');
close $fh;
{
    require Fcntl;
    open my $held, '+<', "$path.lock" or die $!;
    flock($held, Fcntl::LOCK_EX() | Fcntl::LOCK_NB()) or die $!;
    my $busy = Mediabot::State::ReadOnly::read_json_snapshot($path);
    is($busy->{state},'busy','busy writer still returns immediately');
    close $held;
    is(Mediabot::State::ReadOnly::read_json_snapshot($path)->{state},'fresh',
        'reader recovers after writer releases its lock');
}
done_testing;
