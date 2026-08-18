package FastValidation;

use strict;
use warnings;
use Exporter 'import';
use File::Basename qw(basename);

our @EXPORT_OK = qw(
    fast_lane_reason
    fast_lane_sentinels
    fast_lane_slow_exclusions
    select_fast_files
    validate_fast_lane_sentinels
);

# MB661: the fast lane is deliberately explicit and conservative.
#
# It consists of:
#   1. tests whose MB660 primary classification is PURE, except a reviewed
#      manifest of known-slow development cases measured by the profiler; plus
#   2. a small fail-closed sentinel set for cross-cutting runner/runtime
#      contracts. Sentinels always win, even when one is known-slow.
#
# This is a development validation lane, not a replacement for the full suite.
# The slow manifest is an optimisation hint only: excluded cases still belong
# in targeted regressions and in the default full suite.
my %SENTINELS = (
    '83_admincommands_dispatch_exports.t'
        => 'admin/public export contract',
    '86_module_structure_sanity.t'
        => 'module compile/load structure',
    '383_dispatch_integrity.t'
        => 'public dispatch integrity',
    '523_mb301_test_runner_crash_guard.t'
        => 'runner assertion/crash guard',
    '555_mb333_test_runner_isolates_exit_cases.t'
        => 'standalone TAP exit isolation',
    '556_mb335_test_runner_contract_isolation.t'
        => 'runner contract isolation',
    '664_mb449_startup_integrity_check.t'
        => 'startup integrity contract',
    '680_mb469_startup_integrity_check.t'
        => 'startup integrity execution guard',
    '832_mb650_test_suite_profiler.t'
        => 'test-suite profiler contract',
    '842_mb660_test_classification.t'
        => 'test classification contract',
    '843_mb661_fast_validation_lane.t'
        => 'fast validation lane contract',
);


# Measured by the first real MB661 --fast profiler run on 2026-08-18.
# These tests accounted for most of the original 425s fast-lane runtime.
# Keep the manifest explicit and reviewable rather than inferring "fast" from
# capability tags: PURE means dependency-light, not necessarily quick.
my %SLOW_EXCLUSIONS = (
    '612_mb394_trivia_rate_limit_retry.t'
        => 'measured slow: retry/backoff timing',
    '239_usercommands_wave4_subs.t'
        => 'measured slow user-command contract',
    '236_usercommands_karmahist.t'
        => 'measured slow karma history contract',
    '707_mb497_seen_enriched.t'
        => 'measured slow seen enrichment contract',
    '190_seen_respects_channel_scope.t'
        => 'measured slow seen scope contract',
    '192_seen_persisted_respects_channel_scope.t'
        => 'measured slow persisted seen scope contract',
    '335_antiflood_chanflood_public_only.t'
        => 'measured slow antiflood timing contract',
    '55_usercommands_lookup_db_safety.t'
        => 'measured slow lookup safety contract',
    '244_usercommands_poll_ops.t'
        => 'measured slow poll operations contract',
    '258_helpers_db_balance.t'
        => 'measured slow helper DB balance contract',
    '556_mb335_test_runner_contract_isolation.t'
        => 'measured slow but mandatory runner sentinel',
    '219_usercommands_trivia_guard.t'
        => 'measured slow trivia guard contract',
    '84_dispatch_dead_handlers.t'
        => 'measured slow exhaustive dispatch scan',
    '345_dcc_passive_token_redacted.t'
        => 'measured slow DCC contract',
    '380_note_export_lc_key_and_limit.t'
        => 'measured slow note export contract',
);

sub fast_lane_sentinels {
    return sort keys %SENTINELS;
}

sub fast_lane_slow_exclusions {
    return sort keys %SLOW_EXCLUSIONS;
}

sub fast_lane_reason {
    my ($file, $classification) = @_;
    $classification ||= {};

    my $name = basename($file // '');

    # Cross-cutting sentinels are mandatory even when profiling says slow.
    return "sentinel: $SENTINELS{$name}"
        if exists $SENTINELS{$name};

    return if exists $SLOW_EXCLUSIONS{$name};

    return 'primary PURE'
        if ($classification->{primary} // '') eq 'PURE';

    return;
}

sub select_fast_files {
    my ($files, $info_by_file) = @_;
    $files ||= [];
    $info_by_file ||= {};

    return grep {
        defined fast_lane_reason($_, $info_by_file->{$_})
    } @$files;
}

sub validate_fast_lane_sentinels {
    my ($files) = @_;
    $files ||= [];

    my %present = map { basename($_) => 1 } @$files;
    my @missing = grep { !$present{$_} } fast_lane_sentinels();

    return (1, []) unless @missing;
    return (0, \@missing);
}

1;
