package MB1336BatchFixture;
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use BoundedTapBatch qw(run_batch approved_case);
use Time::HiRes qw(sleep);
use POSIX ();

sub run {
    my ($a, $root) = @_;
    my $dir = tempdir('mb1336-contract-XXXXXX', TMPDIR=>1, CLEANUP=>1);
    my $write = sub {
        my ($name, $code) = @_;
        my $path = "$dir/$name";
        open my $f, '>', $path or die $!; print {$f} $code; close $f or die $!;
        return $path;
    };
    my @files;
    for my $i (1..3) {
        push @files, $write->("$i.t", qq{
            use strict; use warnings; use Time::HiRes qw(sleep time);
            open my \$ready,'>', '$dir/ready$i' or die \$!;close \$ready;
            if ($i < 3) {
                my \$deadline=time()+3;
                sleep(.005) while (!-f '$dir/ready1' || !-f '$dir/ready2') && time()<\$deadline;
                die 'peer never started' unless -f '$dir/ready1' && -f '$dir/ready2';
            }
            print '#'.('x'x131072)."\\n";
            print STDERR '#'.('e'x131072)."\\n";
            print "ok 1 - fixture $i\\n1..1\\n";
        });
    }
    my (@results, $live, $peak); $live=$peak=0;
    run_batch(\@files, root=>$root, jobs=>2, timeout=>5,
        on_start=>sub {$live++;$peak=$live if $live>$peak},
        on_finish=>sub {$live--;push @results, [@_]});
    $a->is($peak,2,'bounded TAP batch admits exactly two concurrent interpreters');
    $a->is($live,0,'all admitted interpreters complete');
    $a->is(scalar(@results),3,'every selected case reports exactly once');
    $a->ok(!grep($_->[1]{status} || $_->[1]{timed_out}, @results),
        'peer barrier proves real overlap without a timing-speed assertion');
    $a->ok(!grep(length($_->[1]{output})<262144, @results),
        'large stdout and stderr from both children are captured without pipe deadlock');
    $a->ok(!grep($_->[1]{elapsed}<0, @results),'profiles use nonnegative monotonic child durations');
    for my $jobs (0,3) {
        $a->ok(!eval {run_batch([],root=>$root,jobs=>$jobs,on_finish=>sub {});1},
            "batch refuses unsupported jobs=$jobs");
    }
    $a->ok(approved_case('1433_mb1059_quote_storage_suite.t') &&
        !approved_case('1313_mb883_irc_pacing_native_delivery.t') && !approved_case('unknown.t'),
        'approval is explicit; sensitive pacing and unknown cases remain serial');

    my $slow=$write->('slow.t', qq{
        use Time::HiRes qw(sleep);
        my \$child=fork();die \$! unless defined \$child;
        if (!\$child) {while(1){open my \$f,'>>','$dir/heartbeat' or die \$!;print {\$f} 'x';close \$f;sleep(.01)}}
        sleep(10);
    });
    my $timed;
    run_batch([$slow],root=>$root,jobs=>1,timeout=>.3,on_finish=>sub {$timed=$_[1]});
    $a->ok($timed->{timed_out} && $timed->{status},'a hung case becomes a failed result');
    $a->like($timed->{output},qr/Bail out!.*exceeded/,'timeout has an explicit TAP diagnostic');
    my $size = -s "$dir/heartbeat"; sleep(.06);
    $a->ok(defined($size) && $size == (-s "$dir/heartbeat"),
        'timeout stops the interpreter process group, including its heartbeat child');
    my $error;
    eval {run_batch([$slow],root=>$root,on_start=>sub {die "callback stopped batch\n"},on_finish=>sub {});1} or $error=$@;
    $a->like($error//'',qr/callback stopped batch/,'callback failure is propagated after child cleanup');

    my $interrupted;
    eval {run_batch([$slow],root=>$root,on_start=>sub {kill 'TERM', $$; sleep(.01)},on_finish=>sub {});1}
        or $interrupted=$@;
    $a->like($interrupted//'',qr/TAP batch terminated/,'parent termination interrupts and cleans the batch');
    $a->is(waitpid(-1, POSIX::WNOHANG()),-1,'timeout, callback error and interruption leave no direct child to reap');

    # MB1337: a completed leader must not leave an owned worker behind.
    for my $exit (0,2) {
        my $beat="$dir/finished-$exit.beat";
        my $pidfile="$dir/finished-$exit.pid";
        my $finished=$write->("finished-$exit.t", qq{
            use Time::HiRes qw(sleep time);use POSIX ();
            my \$pid=fork();die \$! unless defined \$pid;
            if (!\$pid) {
                for (1..200) {open my \$f,'>>','$beat' or die \$!;print {\$f} 'x';close \$f;sleep(.01)}
                POSIX::_exit(0);
            }
            open my \$f,'>','$pidfile' or die \$!;print {\$f} \$pid;close \$f;
            my \$end=time()+2;sleep(.005) while !-s '$beat' && time()<\$end;
            die 'worker never started' unless -s '$beat';
            print "ok 1 - completed leader\\n1..1\\n";exit $exit;
        });
        my $result;
        run_batch([$finished],root=>$root,on_finish=>sub {$result=$_[1]});
        my $before=-s $beat;sleep(.06);my $after=-s $beat;
        # Bound the regression fixture even when run against the old executor.
        open my $pidfh,'<',$pidfile or die $!;my $pid=<$pidfh>;close $pidfh;kill 'KILL',$pid;
        $a->is($result->{status},$exit<<8,"leader exit $exit is preserved after descendant cleanup");
        $a->ok(defined($before) && $before==$after,
            "leader exit $exit leaves no active heartbeat descendant");
        $a->like($result->{output},qr/ok 1 - completed leader/,"leader exit $exit retains its TAP output");
    }

    # Exercise the actual runner/parser with temporary cases, never edit live cases.
    my $mini="$dir/repo";make_path("$mini/t/cases");
    copy("$root/t/test_commands.pl","$mini/t/test_commands.pl") or die $!;
    symlink "$root/t/lib", "$mini/t/lib" or die $!;
    my @names=qw(1433_mb1059_quote_storage_suite.t 1434_mb1059_user_read_suite.t);
    my $put=sub {my($name,$code)=@_;open my $f,'>',"$mini/t/cases/$name" or die $!;print {$f} $code;close $f};
    $put->($names[1],q{print "ok 1 - independent good case\n1..1\n";});
    $put->('99999_serial.t',q{return sub {$_[0]->ok(1,'unlisted closure still runs')}});
    my $capture=sub {
        my ($jobs,@extra)=@_;
        local $ENV{PERL5LIB}=join(':',$root,$ENV{PERL5LIB}//'');
        open my $p,'-|',$^X,"$mini/t/test_commands.pl",(defined($jobs)?('--jobs',$jobs):()),'--progress',@extra or die $!;
        local $/;my $out=<$p>//'';close $p;return ($out,$?>>8);
    };
    for my $row (
        ['assertion',q{print "not ok 1 - intentional failure\n1..1\n";exit 1}],
        ['exception',q{die "intentional exception\n"}],
        ['signal',q{$|=1;print "ok 1\n1..1\n";kill 'TERM',$$}],
        ['bailout',q{print "Bail out! intentional bailout\n"}],
        ['bad plan',q{print "ok 1\n1..2\n"}],
        ['exit status',q{print "ok 1\n1..1\n";exit 2}],
    ) {
        $put->($names[0],$row->[1]);
        my ($out,$rc)=$capture->(2);
        $a->ok($rc!=0 && $out=~/FAILED\s*:/,"$row->[0] cannot become a parallel pass");
        $a->like($out,qr/3\/3 files/,'failure still accounts for the second suite and serial closure');
    }
    $put->($names[0],q{print "ok 1 - good fixture\n1..1\n";});
    my ($serial,$src)=$capture->(1);my ($parallel,$prc)=$capture->(2,'--profile-top',3);
    $a->ok(!$src && !$prc && $serial=~/PASSED\s*:\s*3\/3/ && $parallel=~/PASSED\s*:\s*3\/3/,
        'serial and bounded-parallel runs count identical selected assertions');
    my ($default,$drc)=$capture->(undef);
    $a->ok(!$drc && $default=~/PASSED\s*:\s*3\/3/ && $default=~/\[jobs=2\]/,
        'ordinary runner command uses the host-accepted bounded batch by default');
    $a->unlike($serial,qr/\[jobs=2\]/,'explicit --jobs 1 retains sequential execution');
    $a->like($parallel,qr/Profiled 3 test file/,'batch and serial cases each contribute one profile row');
    for my $jobs (0,3) {my (undef,$rc)=$capture->($jobs);$a->ok($rc!=0,"runner CLI rejects jobs=$jobs")}
    my ($narrow,$nrc)=$capture->(2,'--filter','99999');
    $a->ok(!$nrc && $narrow=~/PASSED\s*:\s*1\/1/,'filtering cannot run unselected approved cases');
}
1;
