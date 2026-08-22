# t/cases/883_mb681_doctor_durable_update_status.t
# =============================================================================
# mb681 — Doctor consumes MB680 durable updater status, strictly read-only.
#
# Locks the operator semantics rather than one host:
#   - no record is INFO, not a fabricated success/failure;
#   - SUCCESS is OK only when the recorded installed version matches the tree;
#   - FAILED / ROLLED BACK remain WARN because the current tree may be healthy;
#   - RUNNING is INFO only while the recorded updater still looks live/current;
#   - dead/reused/stale updater PIDs are WARN;
#   - durable detail is sanitised before entering Doctor facts;
#   - the updater-status fact explicitly records network_used => 0.
# =============================================================================

use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

my $TOOL = File::Spec->catfile($Bin, '..', '..', 'tools', 'mediabot_doctor.pl');

return sub {
    my ($assert) = @_;

    my $loaded = do $TOOL;
    $assert->ok($loaded, 'mb681-883: Doctor loads');
    $assert->is($main::VERSION, '1.2',
        'mb681-883: Doctor tool version advances to 1.2');
    $assert->is(main::UPDATE_RUNNING_STALE_SECONDS(), 3600,
        'mb681-883: stale-running threshold is explicit and stable');

    my $uprobe = $main::PROBES{updater};

    my $base = sub {
        my (%extra) = @_;
        return {
            eligible => 1,
            eligibility_reason => undef,
            family => {
                ok => 1, family => 'mediabot_v3', parent => '/home/mediabot',
                archives => [], ignored_sibling_families => [],
            },
            git_executable => '/usr/bin/git',
            git => { is_repo => 1, dirty_count => 0, branch => 'master', head => 'abc' },
            tree_version => '3.4dev-current',
            %extra,
        };
    };

    # ------------------------------------------------------------------
    # [1] No durable history is neutral information, never fake health.
    # ------------------------------------------------------------------
    my %none = map { $_->{id} => $_ } $uprobe->{evaluate}->($base->(
        update_status_error => 'no update status recorded',
    ), {});
    $assert->is($none{'updater.last_update'}{level}, 'info',
        'mb681-883: no durable record is INFO');
    $assert->is($none{'updater.last_update'}{data}{recorded}, 0,
        'mb681-883: absence of history is machine-visible');
    $assert->is($none{'updater.last_update'}{data}{network_used}, 0,
        'mb681-883: durable history diagnostic explicitly uses no network');

    my %broken_record = map { $_->{id} => $_ } $uprobe->{evaluate}->($base->(
        update_status_error => 'invalid update status record',
    ), {});
    $assert->is($broken_record{'updater.last_update'}{level}, 'warn',
        'mb681-883: malformed/unreadable durable status is WARN');

    # ------------------------------------------------------------------
    # [2] Successful update must agree with the inspected tree.
    # ------------------------------------------------------------------
    my $success = {
        schema => 1, state => 'success', phase => 'completed',
        started_at => 100, finished_at => 200, updater_pid => 123,
        old_version => '3.4dev-old', target_version => '3.4dev-current',
        installed_version => '3.4dev-current',
    };
    my %ok = map { $_->{id} => $_ } $uprobe->{evaluate}->($base->(
        update_status => $success,
    ), {});
    $assert->is($ok{'updater.last_update'}{level}, 'ok',
        'mb681-883: successful matching update is OK');
    $assert->like($ok{'updater.last_update'}{summary}, qr/3\.4dev-old -> 3\.4dev-current/,
        'mb681-883: success summary exposes old -> installed version');
    $assert->is($ok{'updater.last_update'}{data}{tree_version}, '3.4dev-current',
        'mb681-883: current tree version stays machine-visible');

    my %mismatch = map { $_->{id} => $_ } $uprobe->{evaluate}->($base->(
        update_status => { %$success, installed_version => '3.4dev-other' },
    ), {});
    $assert->is($mismatch{'updater.last_update'}{level}, 'warn',
        'mb681-883: success record disagreeing with current tree is WARN');
    $assert->like($mismatch{'updater.last_update'}{detail}, qr/current tree .* differs/i,
        'mb681-883: tree/version mismatch is explained');

    my %target_mismatch = map { $_->{id} => $_ } $uprobe->{evaluate}->($base->(
        update_status => { %$success, target_version => '3.4dev-target-other' },
    ), {});
    $assert->is($target_mismatch{'updater.last_update'}{level}, 'warn',
        'mb681-883: target/installed inconsistency is WARN');

    my %missing_finish = map { $_->{id} => $_ } $uprobe->{evaluate}->($base->(
        update_status => { %$success, finished_at => undef },
    ), {});
    $assert->is($missing_finish{'updater.last_update'}{level}, 'warn',
        'mb681-883: success without finish timestamp is WARN');

    # ------------------------------------------------------------------
    # [3] Failure/rollback are durable history warnings, not UNSAFE by fiat.
    # ------------------------------------------------------------------
    my %failed = map { $_->{id} => $_ } $uprobe->{evaluate}->($base->(
        update_status => {
            schema => 1, state => 'failed', phase => 'live_validation',
            started_at => 100, finished_at => 160, updater_pid => 222,
            old_version => '3.4dev-current', target_version => '3.4dev-new',
            detail => 'token=supersecret validation failed',
        },
    ), {});
    $assert->is($failed{'updater.last_update'}{level}, 'warn',
        'mb681-883: failed update is WARN');
    $assert->unlike($failed{'updater.last_update'}{detail}, qr/supersecret/,
        'mb681-883: update failure detail is sanitised before entering facts');
    $assert->like($failed{'updater.last_update'}{detail}, qr/token=<redacted>/,
        'mb681-883: obvious secret assignment is visibly redacted');

    my %rolled = map { $_->{id} => $_ } $uprobe->{evaluate}->($base->(
        update_status => {
            schema => 1, state => 'rolled_back', phase => 'live_validation',
            started_at => 100, finished_at => 170, updater_pid => 333,
            old_version => '3.4dev-current', target_version => '3.4dev-new',
            installed_version => '3.4dev-current', detail => 'rollback restored previous tree',
        },
    ), {});
    $assert->is($rolled{'updater.last_update'}{level}, 'warn',
        'mb681-883: rolled-back update remains visible as WARN');
    $assert->like($rolled{'updater.last_update'}{summary}, qr/rolled back/i,
        'mb681-883: rollback is explicit in the human summary');

    # ------------------------------------------------------------------
    # [4] Running status distinguishes healthy, dead/reused and stale PIDs.
    # ------------------------------------------------------------------
    my $running = {
        schema => 1, state => 'running', phase => 'staged_validation',
        started_at => 100, updater_pid => 444,
        old_version => '3.4dev-current', target_version => '3.4dev-new',
    };
    my %run_ok = map { $_->{id} => $_ } $uprobe->{evaluate}->($base->(
        update_status => $running,
        update_status_age => 120,
        updater_process_alive => 1,
        updater_process_matches => 1,
    ), {});
    $assert->is($run_ok{'updater.last_update'}{level}, 'info',
        'mb681-883: recent matching live updater is INFO');

    my %dead = map { $_->{id} => $_ } $uprobe->{evaluate}->($base->(
        update_status => $running,
        update_status_age => 120,
        updater_process_alive => 0,
    ), {});
    $assert->is($dead{'updater.last_update'}{level}, 'warn',
        'mb681-883: running record with dead updater PID is WARN');
    $assert->like($dead{'updater.last_update'}{detail}, qr/not alive/,
        'mb681-883: dead PID reason is visible');

    my %reused = map { $_->{id} => $_ } $uprobe->{evaluate}->($base->(
        update_status => $running,
        update_status_age => 120,
        updater_process_alive => 1,
        updater_process_matches => 0,
    ), {});
    $assert->is($reused{'updater.last_update'}{level}, 'warn',
        'mb681-883: live but unrelated PID is WARN');
    $assert->like($reused{'updater.last_update'}{detail}, qr/does not look like deploy_update\.sh/,
        'mb681-883: PID-reuse suspicion is explicit');

    my %stale = map { $_->{id} => $_ } $uprobe->{evaluate}->($base->(
        update_status => $running,
        update_status_age => 3601,
        updater_process_alive => 1,
        updater_process_matches => 1,
    ), {});
    $assert->is($stale{'updater.last_update'}{level}, 'warn',
        'mb681-883: updater running beyond one hour is WARN');
    $assert->is($stale{'updater.last_update'}{data}{stale_after_seconds}, 3600,
        'mb681-883: stale threshold is machine-visible');

    # ------------------------------------------------------------------
    # [5] Source/public documentation contracts.
    # ------------------------------------------------------------------
    my $source = do {
        open my $fh, '<:encoding(UTF-8)', $TOOL or die $!;
        local $/; <$fh>;
    };
    $assert->like($source, qr/Mediabot::Update::update_status_record\(\$view\)/,
        'mb681-883: Doctor consumes the public MB680 status reader');
    $assert->like($source, qr/id => 'updater\.last_update'/,
        'mb681-883: durable history has a stable fact id');
    $assert->like($source, qr/network_used => 0/,
        'mb681-883: source locks local-only status observation');
    $assert->unlike($source, qr/update_status_record[\s\S]{0,500}(?:fetch|ls-remote)/,
        'mb681-883: durable status collection does not add a remote Git operation');

    my $readme = do {
        my $path = File::Spec->catfile($Bin, '..', '..', 'README.md');
        open my $fh, '<:encoding(UTF-8)', $path or die $!;
        local $/; <$fh>;
    };
    $assert->like($readme, qr/durable result of the last\s+built-in updater run/i,
        'mb681-883: README documents durable updater history in Doctor');
    $assert->like($readme, qr/--domain updater/,
        'mb681-883: README exposes updater-only Doctor mode');
};
