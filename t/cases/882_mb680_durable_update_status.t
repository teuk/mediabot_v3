# t/cases/882_mb680_durable_update_status.t
# =============================================================================
# mb680 — durable local updater observability.
#
# Locks four guarantees:
#   1. the updater writes one atomic status record BESIDE the rotating tree;
#   2. success/failure/rollback and old->target->installed versions survive;
#   3. `update status` is local-only (no GitHub, no eligibility/apply path);
#   4. malformed/control-character status data is never echoed to IRC.
# =============================================================================

use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json);

{
    package MB680Log;
    sub new { bless {}, shift }
    sub log { 1 }
}

{
    package MB680Ctx;
    sub new { my ($class, %p) = @_; bless \%p, $class }
    sub bot { $_[0]{bot} }
    sub nick { $_[0]{nick} // 'Operator' }
    sub channel { $_[0]{channel} }
    sub args { $_[0]{args} || [] }
    sub message { {} }
    sub require_level {
        my ($self, $level) = @_;
        push @{ $self->{asked} }, $level;
        return $self->{allow} ? 1 : 0;
    }
}

sub _slurp_882 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

sub _write_json_882 {
    my ($path, $data) = @_;
    open my $fh, '>:raw', $path or die "$path: $!";
    print {$fh} encode_json($data), "\n";
    close $fh or die "$path: $!";
}

return sub {
    my ($assert) = @_;

    require Mediabot::Update;

    # ------------------------------------------------------------------
    # [1] Structured reader: valid records survive, malformed ones don't.
    # ------------------------------------------------------------------
    my $tmp = tempdir(CLEANUP => 1);
    my $status = File::Spec->catfile($tmp, '.mediabot_v3.update-status.json');

    {
        no warnings 'redefine';
        local *Mediabot::Update::_update_status_path = sub { $status };

        _write_json_882($status, {
            schema            => 1,
            state             => 'success',
            phase             => 'completed',
            started_at        => 1_787_000_000,
            finished_at       => 1_787_000_042,
            updater_pid       => 4242,
            old_version       => '3.4dev-old',
            target_version    => '3.4dev-new',
            installed_version => '3.4dev-new',
        });

        my ($ok, $why) = Mediabot::Update::update_status_record(bless({}, 'Mediabot'));
        $assert->ok($ok && !defined $why,
            'mb680-882: valid durable status record is accepted');
        $assert->is($ok->{state}, 'success',
            'mb680-882: success state survives decoding');
        $assert->is($ok->{old_version}, '3.4dev-old',
            'mb680-882: previous version is retained');
        $assert->is($ok->{installed_version}, '3.4dev-new',
            'mb680-882: installed version is retained');

        _write_json_882($status, {
            schema => 1, state => 'wizardry', phase => 'completed',
            started_at => 1_787_000_000,
        });
        my ($bad_state, $bad_state_why) =
            Mediabot::Update::update_status_record(bless({}, 'Mediabot'));
        $assert->ok(!$bad_state && $bad_state_why =~ /state/,
            'mb680-882: unknown status state is rejected');

        _write_json_882($status, {
            schema => 1, state => 'failed', phase => 'clone',
            started_at => 1_787_000_000,
            detail => "clone failed\nPRIVMSG #ops :injected",
        });
        my ($bad_text, $bad_text_why) =
            Mediabot::Update::update_status_record(bless({}, 'Mediabot'));
        $assert->ok(!$bad_text && $bad_text_why =~ /detail/,
            'mb680-882: control characters in displayed detail are rejected');

        unlink $status;
        my ($none, $none_why) =
            Mediabot::Update::update_status_record(bless({}, 'Mediabot'));
        $assert->ok(!$none && $none_why eq 'no update status recorded',
            'mb680-882: absent history is explicit, not fabricated');
    }

    # ------------------------------------------------------------------
    # [2] `update status` stays local-only and remains Master-protected.
    # ------------------------------------------------------------------
    {
        no warnings 'redefine';
        no warnings 'once';

        my @out;
        my $network = 0;
        my $spawned = 0;
        my $eligibility = 0;

        local *Mediabot::Helpers::botPrivmsg = sub {
            push @out, $_[2];
            return 1;
        };
        local *Mediabot::Helpers::botNotice = sub {
            push @out, $_[2];
            return 1;
        };
        local *Mediabot::Helpers::getVersion_async = sub {
            $network++;
            return 1;
        };
        local *Mediabot::Update::_spawn_updater = sub {
            $spawned++;
            return 1;
        };
        local *Mediabot::Update::update_eligibility = sub {
            $eligibility++;
            return (0, 'protected');
        };
        local *Mediabot::Update::_read_local_version = sub {
            return '3.4dev-live';
        };
        local *Mediabot::Update::update_status_record = sub {
            return ({
                schema            => 1,
                state             => 'success',
                phase             => 'completed',
                started_at        => 1_787_000_000,
                finished_at       => 1_787_000_042,
                updater_pid       => 4242,
                old_version       => '3.4dev-old',
                target_version    => '3.4dev-live',
                installed_version => '3.4dev-live',
            }, undef);
        };

        my $bot = bless { logger => MB680Log->new }, 'Mediabot';
        my $ctx = MB680Ctx->new(
            bot => $bot, allow => 1, nick => 'Operator',
            channel => '#ops', args => ['status'],
        );

        my $rc = Mediabot::Update::update_ctx($ctx);
        $assert->is($rc, 1,
            'mb680-882: update status completes normally');
        $assert->is(join(',', @{ $ctx->{asked} || [] }), 'Master',
            'mb680-882: update status remains Master-only');
        $assert->is($network, 0,
            'mb680-882: update status never calls GitHub/version worker');
        $assert->is($spawned, 0,
            'mb680-882: update status never launches updater');
        $assert->is($eligibility, 0,
            'mb680-882: local history remains readable on protected deployments');
        $assert->like(join("\n", @out), qr/Mediabot update status/,
            'mb680-882: status heading is visible');
        $assert->like(join("\n", @out), qr/3\.4dev-old\s+->\s+3\.4dev-live/,
            'mb680-882: old-to-installed transition is visible');
        $assert->like(join("\n", @out), qr/SUCCESS/,
            'mb680-882: final result is visible');
    }

    # ------------------------------------------------------------------
    # [3] Source contract for stable, atomic shell persistence.
    # ------------------------------------------------------------------
    my $update = _slurp_882('Mediabot/Update.pm');
    my $deploy = _slurp_882('install/deploy_update.sh');
    my $main   = _slurp_882('Mediabot/Mediabot.pm');

    $assert->like($update, qr/return _show_update_status\(\$ctx\) if \$verb eq 'status'/,
        'mb680-882: status has a dedicated local branch');
    my $status_branch = index($update, q{return _show_update_status($ctx) if $verb eq 'status'});
    my $eligibility_branch = index($update, 'update_eligibility(',
        index($update, 'sub update_ctx'));
    my $network_branch = index($update, 'getVersion_async($self, $done)',
        index($update, 'sub update_ctx'));
    $assert->ok($status_branch >= 0
            && $eligibility_branch > $status_branch
            && $network_branch > $status_branch,
        'mb680-882: local status returns before eligibility and network work');

    $assert->like($deploy,
        qr/STATUS_FILE="\$\{PARENT_DIR\}\/\.\$\{PROJECT_NAME\}\.update-status\.json"/,
        'mb680-882: durable state lives beside the rotating release tree');
    $assert->like($deploy, qr/STATUS_OLD_VERSION=.*?\$\{PROJECT_DIR\}\/VERSION/s,
        'mb680-882: updater captures the previous live version');
    $assert->like($deploy, qr/STATUS_TARGET_VERSION=.*?\$\{TMP_CLONE_DIR\}\/VERSION/s,
        'mb680-882: updater captures the staged target version');
    $assert->like($deploy, qr/STATUS_INSTALLED_VERSION=.*?\$\{PROJECT_DIR\}\/VERSION/s,
        'mb680-882: updater captures the post-activation installed version');
    $assert->like($deploy, qr/write_update_status "success".*?STATUS_FINALIZED=1/s,
        'mb680-882: successful deployment finalizes durable status');
    $assert->like($deploy, qr/state="failed".*?state="rolled_back"/s,
        'mb680-882: EXIT trap distinguishes failure from successful rollback');
    $assert->like($deploy, qr/\.tmp\.\$\$.*?mv -f "\$tmp" "\$STATUS_FILE"/s,
        'mb680-882: status persistence is atomic');
    $assert->like($deploy, qr/status_checkpoint "clone"/,
        'mb680-882: running state exposes clone phase');
    $assert->like($deploy, qr/status_checkpoint "live_validation"/,
        'mb680-882: running state exposes live-validation phase');

    $assert->unlike($deploy, qr/MEDIABOT_UPDATE_STATUS_(?:PASS|PASSWORD|TOKEN|SECRET)/,
        'mb680-882: durable status schema carries no secret values');

    $assert->like($main, qr/update \[check\\\|status\\\|now\]/,
        'mb680-882: help advertises local status');
    $assert->unlike($main, qr/Disabled IRC update command/,
        'mb680-882: stale contradictory update help entry is removed');
};
