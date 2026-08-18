use strict;
use warnings;
use FindBin qw($Bin);
use File::Basename qw(basename);
use File::Spec;
use lib File::Spec->catdir($Bin, '..', 'lib');

use TestClassifier qw(
    allowed_test_classes
    classify_test_file
    classify_test_source
);

my $runner = File::Spec->catfile($Bin, '..', 'test_commands.pl');
my $cases  = File::Spec->catdir($Bin);

sub _capture_runner {
    my (@args) = @_;

    my $pid = open(my $fh, '-|');
    return ('', 255) unless defined $pid;

    if ($pid == 0) {
        open STDERR, '>&', STDOUT or exit 254;
        exec($^X, $runner, @args) or do {
            print "cannot exec classification runner: $!\n";
            exit 254;
        };
    }

    local $/;
    my $output = <$fh> // '';
    close $fh;
    return ($output, $? >> 8);
}

sub _tags {
    my ($info) = @_;
    return { map { $_ => 1 } @{ $info->{tags} // [] } };
}

return sub {
    my ($assert) = @_;

    $assert->is(
        join(',', allowed_test_classes()),
        'PURE,FILESYSTEM,PROCESS,DB,NETWORK',
        'mb660-842: classifier exposes the roadmap capability vocabulary',
    );

    my $pure = classify_test_source('my $x = 1 + 1;');
    $assert->is($pure->{primary}, 'PURE',
        'mb660-842: source with no external touchpoint is PURE');
    $assert->is(join(',', @{ $pure->{tags} }), 'PURE',
        'mb660-842: PURE is the sole tag when no capability is detected');

    my $fs = classify_test_source(q{
        use File::Temp qw(tempdir);
        open my $fh, '<', 'README.md';
    });
    my $fs_tags = _tags($fs);
    $assert->ok($fs_tags->{FILESYSTEM},
        'mb660-842: filesystem touchpoints receive FILESYSTEM');

    my $proc = classify_test_source(q{
        my $pid = fork();
        exec($^X, '-e', 'exit 0');
    });
    my $proc_tags = _tags($proc);
    $assert->ok($proc_tags->{PROCESS},
        'mb660-842: fork/exec touchpoints receive PROCESS');

    my $db = classify_test_source(q{
        my $sth = $dbh->prepare('SELECT id FROM USER');
    });
    my $db_tags = _tags($db);
    $assert->ok($db_tags->{DB},
        'mb660-842: SQL/DB handle touchpoints receive DB');

    my $net = classify_test_source(q{
        use IO::Socket::INET;
        my $sock = IO::Socket::INET->new();
    });
    my $net_tags = _tags($net);
    $assert->ok($net_tags->{NETWORK},
        'mb660-842: socket touchpoints receive NETWORK');

    my $multi = classify_test_source(q{
        use File::Temp qw(tempdir);
        my $sth = $dbh->prepare('SELECT id FROM USER');
        system('true');
    });
    my $multi_tags = _tags($multi);
    $assert->ok(
        $multi_tags->{FILESYSTEM}
            && $multi_tags->{PROCESS}
            && $multi_tags->{DB},
        'mb660-842: capability tags overlap instead of discarding information',
    );
    $assert->is($multi->{primary}, 'DB',
        'mb660-842: conservative primary precedence chooses DB over process/filesystem');

    my $isolated = classify_test_source('1;', isolated => 1);
    my $isolated_tags = _tags($isolated);
    $assert->ok($isolated_tags->{PROCESS},
        'mb660-842: isolated TAP execution forces PROCESS classification');

    my @files = sort glob(File::Spec->catfile($cases, '*.t'));
    $assert->ok(@files >= 700,
        'mb660-842: classification audit sees the complete large case catalogue');

    my %valid = map { $_ => 1 } allowed_test_classes();
    my $all_valid = 1;
    my %primary_count;
    for my $file (@files) {
        my $info = classify_test_file($file);
        $all_valid &&= $valid{ $info->{primary} } ? 1 : 0;
        $all_valid &&= @{ $info->{tags} } ? 1 : 0;
        $primary_count{ $info->{primary} }++;
    }
    $assert->ok($all_valid,
        'mb660-842: every real case receives a valid non-empty classification');
    my $primary_total = 0;
    $primary_total += $primary_count{$_} // 0 for keys %valid;
    $assert->is(
        $primary_total,
        scalar(@files),
        'mb660-842: primary-class counts cover every discovered case exactly once',
    );

    my ($summary, $summary_rc) = _capture_runner(
        '--filter',
        '01_context|833_mb651_asyncworker_contract',
        '--class-summary',
    );
    $assert->is($summary_rc, 0,
        'mb660-842: class-summary inspection exits successfully');
    $assert->like(
        $summary,
        qr/Test classification summary/,
        'mb660-842: class-summary prints its heading');
    $assert->like(
        $summary,
        qr/Selected:\s+2\s+of\s+\d+\s+discovered test file/,
        'mb660-842: class-summary reports filtered selection size');
    $assert->like(
        $summary,
        qr/NOT a parallel-safety certification/,
        'mb660-842: summary explicitly refuses to certify parallel safety');
    $assert->unlike(
        $summary,
        qr/\[\s*01_context\.t\s*\]/,
        'mb660-842: class-summary does not execute selected cases');

    my ($pure_list, $pure_rc) = _capture_runner(
        '--filter',
        '01_context|833_mb651_asyncworker_contract',
        '--class', 'PURE',
        '--list-selected',
    );
    $assert->is($pure_rc, 0,
        'mb660-842: PURE selector/list exits successfully');
    $assert->like($pure_list, qr/\b01_context\.t\b/,
        'mb660-842: PURE selector retains the pure context case');
    $assert->unlike($pure_list, qr/\b833_mb651_asyncworker_contract\.t\b/,
        'mb660-842: PURE selector removes the process/DB worker case');

    my ($proc_list, $proc_rc) = _capture_runner(
        '--filter', '833_mb651_asyncworker_contract',
        '--class', 'PROCESS',
        '--list-selected',
    );
    $assert->is($proc_rc, 0,
        'mb660-842: PROCESS selector/list exits successfully');
    $assert->like(
        $proc_list,
        qr/PROCESS[^\n]*833_mb651_asyncworker_contract\.t/,
        'mb660-842: AsyncWorker contract is classified with PROCESS capability',
    );

    my ($run_out, $run_rc) = _capture_runner(
        '--filter', '01_context',
        '--class', 'PURE',
    );
    $assert->is($run_rc, 0,
        'mb660-842: class filtering can execute the normal runner');
    $assert->like($run_out, qr/\[\s*01_context\.t\s*\]/,
        'mb660-842: selected normal case actually executes');
    $assert->like($run_out, qr/PASSED\s*:\s*\d+\/\d+/,
        'mb660-842: class-filtered execution preserves normal verdict');

    my ($bad_out, $bad_rc) = _capture_runner('--class', 'MAGIC');
    $assert->ok($bad_rc != 0,
        'mb660-842: unknown class is rejected');
    $assert->like(
        $bad_out,
        qr/Unknown --class class 'MAGIC'.*PURE.*FILESYSTEM.*PROCESS.*DB.*NETWORK/s,
        'mb660-842: invalid class error lists allowed vocabulary',
    );

    open my $runner_fh, '<', $runner or do {
        $assert->fail("mb660-842: cannot read $runner");
        return;
    };
    my $runner_src = do { local $/; <$runner_fh> };
    close $runner_fh;

    $assert->unlike(
        $runner_src,
        qr/'(?:jobs|parallel)(?:=i)?'/,
        'mb660-842: mb660 does not add a parallel/jobs execution option',
    );
};
