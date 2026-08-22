use strict;
use warnings;
use FindBin qw($Bin);
use File::Basename qw(basename);
use File::Spec;
use File::Temp qw(tempfile);

my $runner = File::Spec->catfile($Bin, '..', 'test_commands.pl');

sub _mb679_capture_runner {
    my (@args) = @_;

    my $pid = open(my $fh, '-|');
    return ('', 255) unless defined $pid;

    if ($pid == 0) {
        open STDERR, '>&', STDOUT or exit 254;
        exec($^X, $runner, @args) or do {
            print "cannot exec progress runner: $!\n";
            exit 254;
        };
    }

    local $/;
    my $output = <$fh> // '';
    close $fh;
    return ($output, $? >> 8);
}

return sub {
    my ($assert) = @_;

    open my $src_fh, '<:encoding(UTF-8)', $runner or do {
        $assert->fail("mb679-871: cannot read $runner: $!");
        return;
    };
    my $src = do { local $/; <$src_fh> };
    close $src_fh;

    $assert->like(
        $src,
        qr/'progress'\s*=>\s*\\\$opt_progress/,
        'mb679-871: --progress CLI option is registered',
    );
    $assert->like(
        $src,
        qr/sub\s+_progress_render\b/,
        'mb679-871: runner owns a dedicated compact progress renderer',
    );
    $assert->like(
        $src,
        qr/tempfile\([^;]+TMPDIR\s*=>\s*1[^;]+UNLINK\s*=>\s*1/s,
        'mb679-871: progress capture uses a real auto-cleaned temporary file',
    );
    $assert->like(
        $src,
        qr/STDOUT->flush\(\)/,
        'mb679-871: progress capture is explicitly flushed',
    );
    $assert->unlike(
        $src,
        qr/14721|14678|14653/,
        'mb679-871: runner does not hard-code a historical assertion total',
    );

    my ($out, $rc) = _mb679_capture_runner(
        '--filter',
        '717_mb507_schema_drift_indexes|831_mb649_schema_drift_normalization',
        '--progress',
    );

    $assert->is($rc, 0,
        'mb679-871: filtered progress run exits successfully');
    $assert->like(
        $out,
        qr/\r\[[=> ]{20}\]\s+50%\s+\[1\/2 files \| \d+ tests\]/,
        'mb679-871: progress updates in place with exact selected-file percentage',
    );
    $assert->like(
        $out,
        qr/\r\[[=> ]{20}\]\s+0%\s+\[0\/2 files \| \d+ tests\] \| running: 717_mb507_schema_drift_indexes\.t/,
        'mb679-871: progress identifies the currently running test file',
    );
    $assert->like(
        $out,
        qr/\r\[={20}\]\s+100%\s+\[2\/2 files \| \d+ tests\]/,
        'mb679-871: final progress line reaches 100 percent',
    );
    $assert->unlike(
        $out,
        qr/\r\[={20}\]\s+100%\s+\[2\/2 files \| \d+ tests\] \| running:/,
        'mb679-871: completed progress line does not report a test as still running',
    );
    $assert->like(
        $out,
        qr/\r\[={20}\]\s+100%\s+\[2\/2 files \| \d+ tests\] +\r\[={20}\]\s+100%\s+\[2\/2 files \| \d+ tests\]\n/,
        'mb679-871: shorter completion line erases stale running-test text on a terminal',
    );
    $assert->unlike(
        $out,
        qr/\[ 717_mb507_schema_drift_indexes\.t \]/,
        'mb679-871: passing per-file headings stay hidden in progress mode',
    );
    $assert->like(
        $out,
        qr/PASSED\s*:\s*\d+\/\d+/,
        'mb679-871: progress mode preserves the normal final verdict',
    );

    my ($plain, $plain_rc) = _mb679_capture_runner(
        '--filter', '717_mb507_schema_drift_indexes',
    );
    $assert->is($plain_rc, 0,
        'mb679-871: normal runner remains successful without --progress');
    $assert->unlike(
        $plain,
        qr/\[ 717_mb507_schema_drift_indexes\.t \]/,
        'mb688-871: normal compact mode hides passing per-file headings',
    );
    $assert->like(
        $plain,
        qr/PASSED\s*:\s*\d+\/\d+/,
        'mb688-871: normal compact mode preserves the final verdict',
    );
    $assert->unlike(
        $plain,
        qr/\r\[[=> ]{20}\]/,
        'mb679-871: progress output remains strictly opt-in',
    );

    my ($verbose, $verbose_rc) = _mb679_capture_runner(
        '--filter', '717_mb507_schema_drift_indexes',
        '--verbose',
    );
    $assert->is($verbose_rc, 0,
        'mb688-871: verbose runner remains successful');
    $assert->like(
        $verbose,
        qr/\[ 717_mb507_schema_drift_indexes\.t \]/,
        'mb688-871: verbose mode preserves detailed per-file headings',
    );

    my ($cases_dir) = File::Spec->catdir($Bin);
    my ($fail_fh, $fail_path) = tempfile(
        'mb679_progress_fail_XXXX',
        SUFFIX => '.t',
        DIR    => $cases_dir,
        UNLINK => 1,
    );
    print {$fail_fh} <<'FAIL_CASE';
use strict;
use warnings;
print "1..2\n";
print "ok 1 - synthetic progress pass\n";
print "not ok 2 - synthetic progress failure\n";
exit(1);
FAIL_CASE
    close $fail_fh;

    my $fail_name = basename($fail_path);
    my ($fail_out, $fail_rc) = _mb679_capture_runner(
        '--filter', '^' . quotemeta($fail_name) . '$',
        '--progress',
    );
    unlink $fail_path;

    $assert->is($fail_rc, 1,
        'mb679-871: failing progress run preserves non-zero verdict');
    $assert->like(
        $fail_out,
        qr/\r\[={20}\]\s+100%.*?Failed test files \(1\).*?not ok 2 - synthetic progress failure/s,
        'mb688-871: compact failure detail is deferred until after the final progress update',
    );
    $assert->like(
        $fail_out,
        qr/FAILED\s*:\s*1\/2/,
        'mb679-871: failing progress run preserves assertion totals',
    );

    my ($conflict, $conflict_rc) =
        _mb679_capture_runner('--progress', '--verbose', '--filter', '717_');
    $assert->ok($conflict_rc != 0,
        'mb679-871: contradictory --progress --verbose invocation is rejected');
    $assert->like(
        $conflict,
        qr/--progress cannot be combined with --verbose/,
        'mb679-871: progress/verbose conflict is explicit',
    );
};
