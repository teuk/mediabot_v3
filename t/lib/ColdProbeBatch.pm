package ColdProbeBatch;
use strict;
use warnings;
use Exporter 'import';
use File::Temp qw(tempdir);
use POSIX qw(WNOHANG _exit);
use Time::HiRes qw(sleep clock_gettime CLOCK_MONOTONIC);
use Errno qw(EINTR);
our @EXPORT_OK = qw(run_perl_probes);

# Only audited, independent cold-import probes use this helper. The ordinary
# test catalogue remains serial. Files avoid stdout/stderr pipe deadlocks.
sub run_perl_probes {
    my ($codes, %opts) = @_;
    die 'codes must be an array' unless ref($codes) eq 'ARRAY';
    my $jobs = $opts{jobs} // 2;
    my $timeout = $opts{timeout} // 120;
    die 'jobs must be 1 or 2' unless $jobs == 1 || $jobs == 2;
    die 'timeout must be positive' unless $timeout > 0;
    my $dir = tempdir('mediabot-cold-probes-XXXX', TMPDIR => 1, CLEANUP => 1);
    my (@results, %running);
    my $next = 0;
    my $now = sub { clock_gettime(CLOCK_MONOTONIC) };
    my $ok = eval {
        while ($next < @$codes || keys %running) {
            while ($next < @$codes && keys(%running) < $jobs) {
                my $index = $next++;
                die 'probe must be a scalar' if !defined($codes->[$index]) || ref($codes->[$index]);
                my $pid = fork();
                die "cannot fork probe: $!" unless defined $pid;
                if (!$pid) {
                    open STDIN, '<', '/dev/null' or _exit(254);
                    open STDOUT, '>', "$dir/$index.out" or _exit(254);
                    open STDERR, '>', "$dir/$index.err" or _exit(254);
                    no warnings 'exec';
                    exec $^X, '-I.', '-It/lib', ($opts{warnings} ? ('-w') : ()), '-e', $codes->[$index];
                    _exit(254);
                }
                $running{$pid} = {index => $index, started => $now->()};
            }
            for my $pid (keys %running) {
                my $row = $running{$pid};
                my $waited = waitpid($pid, WNOHANG);
                my $status = $?;
                next if $waited < 0 && $! == EINTR;
                die "cannot wait for probe $pid: $!" if $waited < 0;
                if (!$waited && $now->() - $row->{started} >= $timeout) {
                    kill 'KILL', $pid;
                    do { $waited = waitpid($pid, 0) } while $waited < 0 && $! == EINTR;
                    $status = $?;
                    die "cannot reap timed-out probe $pid: $!" if $waited != $pid;
                    $row->{timed_out} = 1;
                }
                next unless $waited;
                my %result = (status => $status, timed_out => $row->{timed_out} // 0);
                for my $stream (qw(out err)) {
                    open my $fh, '<:raw', "$dir/$row->{index}.$stream" or die "cannot read probe output: $!";
                    local $/;
                    $result{$stream eq 'out' ? 'stdout' : 'stderr'} = <$fh> // '';
                }
                # Timeout always fails, even if a child raced with the deadline.
                $result{status} ||= 256 if $result{timed_out};
                $result{stderr} .= "\nCold probe timed out\n" if $result{timed_out};
                $results[$row->{index}] = \%result;
                delete $running{$pid};
            }
            sleep(0.01) if keys %running;
        }
        1;
    };
    my $error = $@;
    unless ($ok) {
        kill 'KILL', $_ for keys %running;
        for my $pid (keys %running) {
            1 while waitpid($pid, 0) < 0 && $! == EINTR;
        }
        die $error;
    }
    return \@results;
}
1;
