#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use File::Spec;
use File::Basename qw(basename);
use lib "$FindBin::Bin/../lib";

use FastValidation qw(
    fast_lane_reason
    fast_lane_sentinels
    fast_lane_slow_exclusions
    select_fast_files
    validate_fast_lane_sentinels
);

return sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($FindBin::Bin, '..', '..');
    my $runner = File::Spec->catfile($root, 't', 'test_commands.pl');

    my @sentinels = fast_lane_sentinels();
    $assert->is(scalar(@sentinels), 11,
        'mb661-843: fast lane has a deliberately small sentinel set');


    my @slow = fast_lane_slow_exclusions();
    $assert->is(scalar(@slow), 15,
        'mb661-843: profiler-backed slow manifest is explicit and small');
    my %slow = map { $_ => 1 } @slow;
    $assert->ok($slow{'612_mb394_trivia_rate_limit_retry.t'},
        'mb661-843: real dominant slow case is excluded from normal fast PURE selection');
    $assert->ok($slow{'556_mb335_test_runner_contract_isolation.t'},
        'mb661-843: slow manifest can contain a mandatory sentinel');

    my %sentinel = map { $_ => 1 } @sentinels;
    for my $required (
        '523_mb301_test_runner_crash_guard.t',
        '555_mb333_test_runner_isolates_exit_cases.t',
        '832_mb650_test_suite_profiler.t',
        '842_mb660_test_classification.t',
        '843_mb661_fast_validation_lane.t',
        '86_module_structure_sanity.t',
    ) {
        $assert->ok($sentinel{$required},
            "mb661-843: sentinel manifest contains $required");
    }

    my @synthetic = (
        '/tmp/01_pure.t',
        '/tmp/612_mb394_trivia_rate_limit_retry.t',
        '/tmp/999_process.t',
        '/tmp/523_mb301_test_runner_crash_guard.t',
        '/tmp/556_mb335_test_runner_contract_isolation.t',
    );
    my %info = (
        $synthetic[0] => { primary => 'PURE', tags => ['PURE'] },
        $synthetic[1] => { primary => 'PURE', tags => ['PURE'] },
        $synthetic[2] => { primary => 'PROCESS', tags => ['PROCESS'] },
        $synthetic[3] => { primary => 'PROCESS', tags => ['PROCESS'] },
        $synthetic[4] => { primary => 'PROCESS', tags => ['PROCESS'] },
    );

    my @fast = select_fast_files(\@synthetic, \%info);
    $assert->is(scalar(@fast), 3,
        'mb661-843: fast policy selects quick PURE plus mandatory sentinels');
    $assert->is(basename($fast[0]), '01_pure.t',
        'mb661-843: normal PURE test is selected');
    $assert->is(
        basename($fast[1]),
        '523_mb301_test_runner_crash_guard.t',
        'mb661-843: non-PURE sentinel is selected',
    );
    $assert->is(
        basename($fast[2]),
        '556_mb335_test_runner_contract_isolation.t',
        'mb661-843: mandatory sentinel overrides slow-manifest exclusion',
    );
    $assert->ok(
        !grep(basename($_) eq '612_mb394_trivia_rate_limit_retry.t', @fast),
        'mb661-843: known-slow PURE test is excluded from default fast lane',
    );

    $assert->like(
        fast_lane_reason($synthetic[0], $info{$synthetic[0]}),
        qr/primary PURE/,
        'mb661-843: PURE selection reason is explainable',
    );
    $assert->like(
        fast_lane_reason($synthetic[3], $info{$synthetic[3]}),
        qr/sentinel:/,
        'mb661-843: sentinel selection reason is explainable',
    );
    $assert->ok(
        !defined fast_lane_reason($synthetic[1], $info{$synthetic[1]}),
        'mb661-843: known-slow PURE test is explicitly excluded',
    );
    $assert->ok(
        !defined fast_lane_reason($synthetic[2], $info{$synthetic[2]}),
        'mb661-843: arbitrary non-PURE test is not silently admitted',
    );

    my ($manifest_ok, $missing) =
        validate_fast_lane_sentinels([map { "/tmp/$_" } @sentinels]);
    $assert->ok($manifest_ok,
        'mb661-843: complete sentinel manifest validates');
    $assert->is(scalar(@$missing), 0,
        'mb661-843: complete sentinel manifest reports no missing files');

    my @without_one = grep {
        basename($_) ne '842_mb660_test_classification.t'
    } map { "/tmp/$_" } @sentinels;

    my ($manifest_bad, $missing_bad) =
        validate_fast_lane_sentinels(\@without_one);
    $assert->ok(!$manifest_bad,
        'mb661-843: missing sentinel fails closed');
    $assert->ok(
        grep($_ eq '842_mb660_test_classification.t', @$missing_bad),
        'mb661-843: fail-closed result names the missing sentinel',
    );

    my $capture = sub {
        my (@args) = @_;
        my $pid = open(my $fh, '-|');
        if (!defined $pid) {
            return ('', 255);
        }
        if ($pid == 0) {
            open STDERR, '>&', STDOUT;
            chdir $root or exit 254;
            exec($^X, $runner, @args);
            exit 254;
        }
        local $/;
        my $out = <$fh> // '';
        close $fh;
        return ($out, $? >> 8);
    };

    my ($list, $list_rc) = $capture->('--fast', '--list-selected');
    $assert->is($list_rc, 0,
        'mb661-843: --fast --list-selected exits successfully');
    $assert->like($list, qr/primary PURE[^\n]*01_context\.t/,
        'mb661-843: real fast lane contains a PURE case');
    $assert->like(
        $list,
        qr/sentinel: runner assertion\/crash guard[^\n]*523_mb301_test_runner_crash_guard\.t/,
        'mb661-843: real fast lane contains a non-PURE runner sentinel',
    );
    $assert->unlike(
        $list,
        qr/\b833_mb651_asyncworker_contract\.t\b/,
        'mb661-843: arbitrary PROCESS/DB test stays outside fast lane',
    );
    $assert->unlike(
        $list,
        qr/\b612_mb394_trivia_rate_limit_retry\.t\b/,
        'mb661-843: profiler-confirmed slow PURE case stays outside fast lane',
    );
    $assert->like(
        $list,
        qr/sentinel: runner contract isolation[^\n]*556_mb335_test_runner_contract_isolation\.t/,
        'mb661-843: mandatory slow sentinel remains inside fast lane',
    );

    my ($summary, $summary_rc) =
        $capture->('--fast', '--class-summary');
    $assert->is($summary_rc, 0,
        'mb661-843: --fast --class-summary exits successfully');
    $assert->like(
        $summary,
        qr/Selected:\s+\d+\s+of\s+\d+\s+discovered test file\(s\)/,
        'mb661-843: fast summary makes selected-vs-total coverage explicit',
    );

    my ($narrow, $narrow_rc) = $capture->(
        '--fast',
        '--filter', '01_context|523_mb301_test_runner_crash_guard',
    );
    $assert->is($narrow_rc, 0,
        'mb661-843: filter can narrow an executable fast lane');
    $assert->like($narrow, qr/Fast validation lane/,
        'mb661-843: executable fast lane prints its identity');
    $assert->like(
        $narrow,
        qr/NOT equivalent to the full suite/,
        'mb661-843: executable fast lane states its coverage limit',
    );
    $assert->like($narrow, qr/PASSED\s*:\s*\d+\/\d+/,
        'mb661-843: narrowed fast lane preserves normal verdict');

    open my $fh, '<', $runner or do {
        $assert->fail("mb661-843: cannot read $runner");
        return;
    };
    my $runner_src = do { local $/; <$fh> };
    close $fh;

    $assert->unlike(
        $runner_src,
        qr/'(?:jobs|parallel)(?:=i)?'/,
        'mb661-843: mb661 still adds no jobs/parallel executor',
    );
};
