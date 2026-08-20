# t/cases/858_mb673_update_completion_notice.t
# =============================================================================
# mb673 — `update now` reports success from the NEW process after restart.
#
# The detached updater is the only process that knows deployment completed.
# It writes a marker only after live-path validation; the restarted bot then
# consumes it once the original reply destination is actually usable.
# =============================================================================

use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json);

{
    package MB673Log;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, $_[2] // ''; 1 }
}

sub _write_marker_858 {
    my ($path, %p) = @_;
    open my $fh, '>:raw', $path or die "$path: $!";
    print {$fh} encode_json({
        schema       => 1,
        kind         => $p{kind},
        target       => $p{target},
        version      => $p{version},
        completed_at => time(),
    }), "\n";
    close $fh or die "$path: $!";
}

sub _slurp_858 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    no warnings 'redefine';
    no warnings 'once';

    require Mediabot::Update;

    # [1] Destination validation is narrow and injection-safe.
    $assert->ok(Mediabot::Update::_safe_notice_target('channel', '#ops'),
        'mb673-858: normal channel target accepted');
    $assert->ok(Mediabot::Update::_safe_notice_target('notice', 'Te[u]K'),
        'mb673-858: normal private target accepted');
    $assert->ok(!Mediabot::Update::_safe_notice_target('channel', 'Te[u]K'),
        'mb673-858: channel kind requires an IRC channel prefix');
    $assert->ok(!Mediabot::Update::_safe_notice_target('notice', "nick\nINJECT"),
        'mb673-858: CR/LF injection is rejected');

    # [2] Channel notice waits for the exact self-JOIN and is consumed once.
    {
        my $dir = tempdir(CLEANUP => 1);
        my $marker = File::Spec->catfile($dir, 'update.completed.json');
        _write_marker_858($marker,
            kind => 'channel', target => '#ops', version => '3.4dev-20260820_090000');

        my (@privmsg, @notice);
        local *Mediabot::Update::_completion_marker_path = sub { $marker };
        local *Mediabot::Update::_read_local_version = sub { '3.4dev-20260820_090000' };
        local *Mediabot::Helpers::botPrivmsg = sub {
            my ($self, $target, $text) = @_;
            push @privmsg, [ $target, $text ];
            return 1;
        };
        local *Mediabot::Helpers::botNotice = sub {
            my ($self, $target, $text) = @_;
            push @notice, [ $target, $text ];
            return 1;
        };

        my $bot = bless { logger => MB673Log->new }, 'Mediabot';

        $assert->is(Mediabot::Update::update_completion_on_login($bot), 0,
            'mb673-858: channel completion is not sent at login');
        $assert->ok(-f $marker,
            'mb673-858: channel marker survives until channel is joined');
        $assert->is(Mediabot::Update::update_completion_on_join($bot, '#other'), 0,
            'mb673-858: unrelated self-JOIN does not consume marker');
        $assert->ok(-f $marker,
            'mb673-858: marker remains after unrelated JOIN');
        $assert->is(Mediabot::Update::update_completion_on_join($bot, '#OPS'), 1,
            'mb673-858: matching channel JOIN sends completion case-insensitively');
        $assert->is(scalar @privmsg, 1,
            'mb673-858: exactly one channel completion message sent');
        $assert->is($privmsg[0][0], '#OPS',
            'mb673-858: completion is sent to the actually joined channel spelling');
        $assert->like($privmsg[0][1], qr/Update completed\./,
            'mb673-858: visible completion wording is present');
        $assert->like($privmsg[0][1], qr/3\.4dev-20260820_090000/,
            'mb673-858: actual installed version is shown');
        $assert->ok(!-e $marker,
            'mb673-858: marker is removed after successful send');
        $assert->is(Mediabot::Update::update_completion_on_join($bot, '#ops'), 0,
            'mb673-858: completion is one-shot after consumption');
        $assert->is(scalar @notice, 0,
            'mb673-858: channel request never falls back to private notice');
    }

    # [3] Private update request reports completion on IRC login.
    {
        my $dir = tempdir(CLEANUP => 1);
        my $marker = File::Spec->catfile($dir, 'update.completed.json');
        _write_marker_858($marker,
            kind => 'notice', target => 'Operator', version => '3.4dev-20260820_091500');

        my @notice;
        local *Mediabot::Update::_completion_marker_path = sub { $marker };
        local *Mediabot::Update::_read_local_version = sub { '3.4dev-20260820_091500' };
        local *Mediabot::Helpers::botNotice = sub {
            my ($self, $target, $text) = @_;
            push @notice, [ $target, $text ];
            return 1;
        };

        my $bot = bless { logger => MB673Log->new }, 'Mediabot';
        $assert->is(Mediabot::Update::update_completion_on_login($bot), 1,
            'mb673-858: private request completes on login');
        $assert->is(scalar @notice, 1,
            'mb673-858: exactly one private completion notice sent');
        $assert->is($notice[0][0], 'Operator',
            'mb673-858: private completion returns to original requester');
        $assert->like($notice[0][1], qr/3\.4dev-20260820_091500/,
            'mb673-858: private completion shows installed version');
        $assert->ok(!-e $marker,
            'mb673-858: private marker is consumed');
    }

    # [4] Stale version marker can never lie after a later/manual deployment.
    {
        my $dir = tempdir(CLEANUP => 1);
        my $marker = File::Spec->catfile($dir, 'update.completed.json');
        _write_marker_858($marker,
            kind => 'channel', target => '#ops', version => '3.4dev-OLD');

        local *Mediabot::Update::_completion_marker_path = sub { $marker };
        local *Mediabot::Update::_read_local_version = sub { '3.4dev-NEW' };

        my $bot = bless { logger => MB673Log->new }, 'Mediabot';
        $assert->is(Mediabot::Update::update_completion_on_join($bot, '#ops'), 0,
            'mb673-858: stale version marker is not announced');
        $assert->ok(!-e $marker,
            'mb673-858: stale marker is discarded');
    }

    # [5] Source contracts: destination survives double-fork via environment,
    # updater writes marker only after successful live validation, and runtime
    # hooks wait for login / self-JOIN rather than a fixed sleep.
    my $update = _slurp_858('Mediabot/Update.pm');
    my $deploy = _slurp_858('install/deploy_update.sh');
    my $main   = _slurp_858('mediabot.pl');

    $assert->like($update, qr/MEDIABOT_UPDATE_NOTIFY_KIND.*?MEDIABOT_UPDATE_NOTIFY_TARGET/s,
        'mb673-858: detached updater inherits completion destination');
    $assert->like($update, qr/kind => 'channel'.*?target => \$reply_channel/s,
        'mb673-858: public update remembers command channel');
    $assert->like($update, qr/kind => 'notice'.*?target => \$nick/s,
        'mb673-858: private update remembers requester');

    my $live_validation = index($deploy, 'Re-checking Perl syntax on the live path');
    my $notice_marker   = index($deploy, 'update.completed.json');
    my $complete        = index($deploy, 'Deployment complete.');
    $assert->ok($live_validation >= 0 && $notice_marker > $live_validation,
        'mb673-858: completion marker is armed only after live validation');
    $assert->ok($complete > $notice_marker,
        'mb673-858: marker is part of successful deployment completion');
    $assert->like($deploy, qr/LIVE_VERSION=.*?\$\{PROJECT_DIR\}\/VERSION/s,
        'mb673-858: marker version comes from the newly activated VERSION file');
    $assert->like($deploy, qr/JSON::PP.*?completed_at/s,
        'mb673-858: updater writes structured completion marker');

    $assert->like($main, qr/update_completion_on_login\(\$mediabot\)/,
        'mb673-858: private completion hook runs after IRC login');
    $assert->like($main, qr/update_completion_on_join\(\$mediabot, \$target_name\)/,
        'mb673-858: channel completion hook runs on self-JOIN');
};
