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
use Test::More;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use File::Temp qw(tempdir);
use Future ();
use IO::Async::Loop;
use IO::Select;
use JSON::PP qw(encode_json);
use Socket qw(AF_UNIX SOCK_STREAM);
use TestLoopWait qw(wait_for);

{
    package MB673Log;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, $_[2] // ''; 1 }
}

{
    package MB673IRC;
    sub is_connected { $_[0]{connected} }
    sub nick_folded { 'mediabot' }
    sub do_NOTICE { push @{ $_[0]{wire} }, { kind => 'notice', @_[1 .. $#_] }; $_[0]{write} }
    sub do_PRIVMSG { push @{ $_[0]{wire} }, { kind => 'channel', @_[1 .. $#_] }; $_[0]{write} }
}

{
    package MB673WireIRC;
    use parent 'Mediabot::IRC::Transport';
    use mro 'c3';
    # The local socket pair stands in for an already connected IRC server.
    sub is_connected { defined $_[0]->write_handle }
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

no warnings 'redefine';
no warnings 'once';

require Mediabot::Update;
require Mediabot::Helpers;

# [1] Destination validation is narrow and injection-safe.
ok(Mediabot::Update::_safe_notice_target('channel', '#ops'),
    'mb673-858: normal channel target accepted');
ok(Mediabot::Update::_safe_notice_target('notice', 'Te[u]K'),
    'mb673-858: normal private target accepted');
ok(!Mediabot::Update::_safe_notice_target('channel', 'Te[u]K'),
    'mb673-858: channel kind requires an IRC channel prefix');
ok(!Mediabot::Update::_safe_notice_target('notice', "nick\nINJECT"),
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
        my ($self, $target, $text, $options) = @_;
        push @privmsg, [ $target, $text ];
        push @{ $options->{write_futures} }, Future->done if $options;
        return 1;
    };
    local *Mediabot::Helpers::botNotice = sub {
        my ($self, $target, $text) = @_;
        push @notice, [ $target, $text ];
        return 1;
    };

    my $bot = bless {
        logger => MB673Log->new, irc => bless({ connected => 1 }, 'MB673IRC'),
    }, 'Mediabot';

    is(Mediabot::Update::update_completion_on_login($bot), 0,
        'mb673-858: channel completion is not sent at login');
    ok(-f $marker,
        'mb673-858: channel marker survives until channel is joined');
    is(Mediabot::Update::update_completion_on_join($bot, '#other'), 0,
        'mb673-858: unrelated self-JOIN does not consume marker');
    ok(-f $marker,
        'mb673-858: marker remains after unrelated JOIN');
    is(Mediabot::Update::update_completion_on_join($bot, '#OPS'), 1,
        'mb673-858: matching channel JOIN sends completion case-insensitively');
    is(scalar @privmsg, 1,
        'mb673-858: exactly one channel completion message sent');
    is($privmsg[0][0], '#OPS',
        'mb673-858: completion is sent to the actually joined channel spelling');
    like($privmsg[0][1], qr/Update completed\./,
        'mb673-858: visible completion wording is present');
    like($privmsg[0][1], qr/3\.4dev-20260820_090000/,
        'mb673-858: actual installed version is shown');
    ok(!-e $marker,
        'mb673-858: marker is removed after successful send');
    is(Mediabot::Update::update_completion_on_join($bot, '#ops'), 0,
        'mb673-858: completion is one-shot after consumption');
    is(scalar @notice, 0,
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
        my ($self, $target, $text, $options) = @_;
        push @notice, [ $target, $text ];
        push @{ $options->{write_futures} }, Future->done if $options;
        return 1;
    };

    my $bot = bless {
        logger => MB673Log->new, irc => bless({ connected => 1 }, 'MB673IRC'),
    }, 'Mediabot';
    is(Mediabot::Update::update_completion_on_login($bot), 1,
        'mb673-858: private request completes on login');
    is(scalar @notice, 1,
        'mb673-858: exactly one private completion notice sent');
    is($notice[0][0], 'Operator',
        'mb673-858: private completion returns to original requester');
    like($notice[0][1], qr/3\.4dev-20260820_091500/,
        'mb673-858: private completion shows installed version');
    ok(!-e $marker,
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
    is(Mediabot::Update::update_completion_on_join($bot, '#ops'), 0,
        'mb673-858: stale version marker is not announced');
    ok(!-e $marker,
        'mb673-858: stale marker is discarded');
}

# Use the real Helpers and Sender paths for refusal and asynchronous write
# completion. The stand-in transport returns the same Future contract.
{
    my $dir = tempdir(CLEANUP => 1);
    my $marker = File::Spec->catfile($dir, 'update.completed.json');
    my $version = '3.8dev-20261107_090000';
    _write_marker_858($marker, kind => 'channel', target => '#ops', version => $version);
    my $flooded = 1;
    local *Mediabot::Update::_completion_marker_path = sub { $marker };
    local *Mediabot::Update::_read_local_version = sub { $version };
    local *Mediabot::Helpers::getIdChansetList = sub { $_[1] eq 'AntiFlood' ? 42 : undef };
    local *Mediabot::Helpers::getIdChannelSet = sub { 1 };
    local *Mediabot::Helpers::checkAntiFlood = sub { $flooded };
    local *Mediabot::Helpers::logBotAction = sub { 1 };
    my $irc = bless { connected => 1, wire => [], write => Future->new }, 'MB673IRC';
    my $bot = bless {
        logger => MB673Log->new, irc => $irc,
        _badword_cache => { '#ops' => { ts => time(), words => [] } },
    }, 'Mediabot';

    my $result = Mediabot::Update::update_completion_on_join($bot, '#ops');
    ok(!$result && -f $marker && !$bot->{_flood_outq} && !@{ $irc->{wire} },
        'mb1129: AntiFlood leaves the completion marker on disk and queues nothing');
    $flooded = 0;
    Mediabot::Update::update_completion_on_join($bot, '#OPS');
    Mediabot::Update::update_completion_on_join($bot, '#ops');
    ok(-f $marker && @{ $irc->{wire} } == 1 && $irc->{wire}[0]{target} eq '#OPS',
        'mb1129: pending channel write retains the marker and prevents duplicate submissions');
    $irc->{write}->done;
    ok(!-e $marker, 'mb1129: channel marker is consumed after the write completes');
}

{
    my $dir = tempdir(CLEANUP => 1);
    my $marker = File::Spec->catfile($dir, 'update.completed.json');
    my $version = '3.8dev-20261107_090000';
    _write_marker_858($marker, kind => 'notice', target => 'Operator', version => $version);
    local *Mediabot::Update::_completion_marker_path = sub { $marker };
    local *Mediabot::Update::_read_local_version = sub { $version };
    my $irc = bless { connected => 0, wire => [], write => Future->new }, 'MB673IRC';
    my $bot = bless { logger => MB673Log->new, irc => $irc }, 'Mediabot';

    Mediabot::Update::update_completion_on_login($bot);
    ok(-f $marker && !@{ $irc->{wire} },
        'mb1129: disconnected private notice does not consume the marker');
    $irc->{connected} = 1;
    Mediabot::Update::update_completion_on_login($bot);
    $irc->{write}->fail('socket closed before write');
    $irc->{write}->failure;
    ok(-f $marker && @{ $irc->{wire} } == 1,
        'mb1129: failed private write remains pending on disk');
    $irc->{write} = Future->done;
    my $retried = Mediabot::Update::update_completion_on_login($bot);
    ok($retried && !-e $marker && @{ $irc->{wire} } == 2,
        'mb1129: the next login retries once and consumes the marker only on success');
}

{
    my $dir = tempdir(CLEANUP => 1);
    my $marker = File::Spec->catfile($dir, 'update.completed.json');
    my $version = '3.8dev-20261107_090000';
    _write_marker_858($marker, kind => 'notice', target => 'Operator', version => $version);
    local *Mediabot::Update::_completion_marker_path = sub { $marker };
    local *Mediabot::Update::_read_local_version = sub { $version };
    socketpair(my $sock, my $peer, AF_UNIX, SOCK_STREAM, 0) or die "socketpair: $!";
    my $loop = IO::Async::Loop->new;
    my $irc = MB673WireIRC->new(handle => $sock, autoflush => 0);
    $loop->add($irc);
    my $bot = bless { logger => MB673Log->new, irc => $irc }, 'Mediabot';
    Mediabot::Update::update_completion_on_login($bot);
    ok(-f $marker && !IO::Select->new($peer)->can_read(0),
        'mb1129: the native stream retains the marker before socket flush');
    my $flushed = wait_for($loop, sub { !-e $marker }, 1);
    my $bytes = '';
    sysread($peer, $bytes, 512) if IO::Select->new($peer)->can_read(0);
    ok($flushed && $bytes eq "NOTICE Operator :\x0309Update completed.\x0f Version: \x02$version\x02\r\n",
        'mb1129: native socket flush writes the exact notice and consumes its marker');
    $irc->close_now;
    close $peer;
}

# [5] Source contracts: destination survives double-fork via environment,
# updater writes marker only after successful live validation, and runtime
# hooks wait for login / self-JOIN rather than a fixed sleep.
my $update = _slurp_858('Mediabot/Update.pm');
my $deploy = _slurp_858('install/deploy_update.sh');
my $main   = _slurp_858('mediabot.pl');

like($update, qr/MEDIABOT_UPDATE_NOTIFY_KIND.*?MEDIABOT_UPDATE_NOTIFY_TARGET/s,
    'mb673-858: detached updater inherits completion destination');
like($update, qr/kind => 'channel'.*?target => \$reply_channel/s,
    'mb673-858: public update remembers command channel');
like($update, qr/kind => 'notice'.*?target => \$nick/s,
    'mb673-858: private update remembers requester');

my $live_validation = index($deploy, 'Re-checking Perl syntax on the live path');
my $notice_marker   = index($deploy, 'update.completed.json');
my $complete        = index($deploy, 'Deployment complete.');
ok($live_validation >= 0 && $notice_marker > $live_validation,
    'mb673-858: completion marker is armed only after live validation');
ok($complete > $notice_marker,
    'mb673-858: marker is part of successful deployment completion');
like($deploy, qr/LIVE_VERSION=.*?\$\{PROJECT_DIR\}\/VERSION/s,
    'mb673-858: marker version comes from the newly activated VERSION file');
like($deploy, qr/JSON::PP.*?completed_at/s,
    'mb673-858: updater writes structured completion marker');

like($main, qr/update_completion_on_login\(\$mediabot\)/,
    'mb673-858: private completion hook runs after IRC login');
like($main, qr/update_completion_on_join\(\$mediabot, \$target_name\)/,
    'mb673-858: channel completion hook runs on self-JOIN');

done_testing;
