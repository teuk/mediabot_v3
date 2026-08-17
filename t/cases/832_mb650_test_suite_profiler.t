use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $runner = File::Spec->catfile($Bin, '..', 'test_commands.pl');

sub _capture_runner {
    my (@args) = @_;

    my $pid = open(my $fh, '-|');
    return ('', 255) unless defined $pid;

    if ($pid == 0) {
        open STDERR, '>&', STDOUT or exit 254;
        exec($^X, $runner, @args) or do {
            print "cannot exec profiler runner: $!\n";
            exit 254;
        };
    }

    local $/;
    my $output = <$fh> // '';
    close $fh;
    my $rc = $? >> 8;
    return ($output, $rc);
}

return sub {
    my ($assert) = @_;

    open my $src_fh, '<', $runner or do {
        $assert->(0, "mb650-832: cannot read $runner: $!");
        return;
    };
    my $src = do { local $/; <$src_fh> };
    close $src_fh;

    $assert->like(
        $src,
        qr/use\s+Time::HiRes\s+\(\);/,
        'mb650-832: runner loads Time::HiRes without importing time into package main',
    );
    $assert->unlike(
        $src,
        qr/use\s+Time::HiRes\s+qw\([^)]*\btime\b[^)]*\)/,
        'mb650-832: profiler does not import time and alter semantics of loaded test cases',
    );
    my $qualified_time_calls = () = $src =~ /Time::HiRes::time\(\)/g;
    $assert->ok(
        $qualified_time_calls >= 2,
        'mb650-832: profiler uses fully-qualified Time::HiRes::time calls',
    );
    $assert->like(
        $src,
        qr/'profile'\s*=>\s*\\\$opt_profile/,
        'mb650-832: --profile CLI option is registered',
    );
    $assert->like(
        $src,
        qr/'profile-top=i'\s*=>\s*\\\$opt_profile_top/,
        'mb650-832: --profile-top CLI option is registered',
    );

    my ($out, $rc) = _capture_runner(
        '--filter',
        '717_mb507_schema_drift_indexes|831_mb649_schema_drift_normalization',
        '--profile',
        '--profile-top', '2',
    );

    $assert->is($rc, 0, 'mb650-832: profiled filtered runner exits successfully');
    $assert->like(
        $out,
        qr/Slowest test files \(top 2 of 2\)/,
        'mb650-832: profile report declares the requested top-N and profiled file count',
    );
    $assert->like(
        $out,
        qr/Profiled 2 test file\(s\); cumulative case time \d+\.\d{3}s/,
        'mb650-832: profile report includes cumulative measured case time',
    );
    $assert->like(
        $out,
        qr/PASSED\s*:\s*\d+\/\d+/,
        'mb650-832: profiling preserves the normal test-suite verdict',
    );

    my @rows;
    for my $line (split /\n/, $out) {
        next unless $line =~ /^[ !]\s*(\d+)\s+(\d+\.\d{3})\s+(runner|isolated|load-error|skip)\s+(\d+)\s+(\S+\.t)\s*$/;
        push @rows, {
            rank       => 0 + $1,
            elapsed    => 0 + $2,
            mode       => $3,
            assertions => 0 + $4,
            file       => $5,
        };
    }

    $assert->is(scalar(@rows), 2, 'mb650-832: report contains exactly two ranked profile rows');
    if (@rows == 2) {
        my %seen = map { $_->{file} => 1 } @rows;
        $assert->ok($seen{'717_mb507_schema_drift_indexes.t'},
            'mb650-832: first selected case is represented in the profile');
        $assert->ok($seen{'831_mb649_schema_drift_normalization.t'},
            'mb650-832: second selected case is represented in the profile');
        $assert->ok($rows[0]{elapsed} >= $rows[1]{elapsed},
            'mb650-832: profile rows are sorted slowest first');
        $assert->is($rows[0]{rank}, 1, 'mb650-832: first profile row has rank 1');
        $assert->is($rows[1]{rank}, 2, 'mb650-832: second profile row has rank 2');
    }


    my ($clock_out, $clock_rc) = _capture_runner(
        '--filter', '397_mb161_reminder_starvation_and_first_occurrence',
        '--profile', '--profile-top', '1',
    );
    $assert->is(
        $clock_rc, 0,
        'mb650-832: profiling does not change CORE time semantics in reminder scheduling tests',
    );
    $assert->unlike(
        $clock_out,
        qr/\[FAIL\]/,
        'mb650-832: reminder time-tag regression stays green under profiling',
    );

    my ($top_out, $top_rc) = _capture_runner(
        '--filter', '717_mb507_schema_drift_indexes',
        '--profile-top', '1',
    );
    $assert->is($top_rc, 0, 'mb650-832: --profile-top alone implies profiling');
    $assert->like(
        $top_out,
        qr/Slowest test files \(top 1 of 1\)/,
        'mb650-832: implied profiling honours the requested top-N',
    );

    my ($plain_out, $plain_rc) = _capture_runner(
        '--filter', '717_mb507_schema_drift_indexes',
    );
    $assert->is($plain_rc, 0, 'mb650-832: normal non-profiled runner still succeeds');
    $assert->unlike(
        $plain_out,
        qr/Slowest test files/,
        'mb650-832: profile output remains opt-in',
    );

    my ($bad_out, $bad_rc) = _capture_runner('--profile-top', '0');
    $assert->ok($bad_rc != 0, 'mb650-832: invalid --profile-top is rejected');
    $assert->like(
        $bad_out,
        qr/--profile-top must be a positive integer/,
        'mb650-832: invalid profile limit has an explicit error',
    );
};
