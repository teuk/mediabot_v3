# MB786 — consolidate MB785 and rehearse updater state preservation end to end.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use Digest::SHA qw(sha256_hex);
use File::Find qw(find);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP ();
use POSIX qw(WNOHANG);

sub _slurp_1151 {
    my ($path, $raw) = @_;
    my $mode = $raw ? '<:raw' : '<:encoding(UTF-8)';
    open my $fh, $mode, $path or die "$path: $!";
    local $/;
    return <$fh>;
}

sub _write_1151 {
    my ($path, $content, $mode) = @_;
    my (undef, $dir) = File::Spec->splitpath($path);
    make_path($dir) if length($dir) && !-d $dir;
    open my $fh, '>:encoding(UTF-8)', $path or die "$path: $!";
    print {$fh} $content;
    close $fh or die "$path: $!";
    chmod($mode, $path) if defined $mode;
}

sub _run_1151 {
    my ($cwd, $log, @command) = @_;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        chdir $cwd or die "chdir $cwd: $!";
        open STDOUT, '>:raw', $log or die "$log: $!";
        open STDERR, '>&', STDOUT or die "dup stderr: $!";
        exec { $command[0] } @command or die "exec $command[0]: $!";
    }
    waitpid($pid, 0);
    return $? >> 8;
}

sub _must_run_1151 {
    my ($cwd, @command) = @_;
    my $log = File::Spec->catfile($cwd, '.mb786-command.log');
    my $rc = _run_1151($cwd, $log, @command);
    die "@command failed ($rc): " . _slurp_1151($log, 1) if $rc;
    unlink $log;
}

sub _tree_manifest_1151 {
    my ($root) = @_;
    my @rows;
    find({
        no_chdir => 1,
        wanted => sub {
            my $path = $File::Find::name;
            return if $path eq $root;
            my $rel = File::Spec->abs2rel($path, $root);
            my @st = lstat($path);
            die "lstat $path: $!" unless @st;
            my $type = -f _ ? 'f' : -d _ ? 'd' : -l _ ? 'l' : 'o';
            my $digest = $type eq 'f'
                ? sha256_hex(_slurp_1151($path, 1))
                : $type eq 'l' ? readlink($path) : '-';
            push @rows, join("\0", $rel, $type,
                sprintf('%04o', $st[2] & 07777),
                $st[4], $st[5], $st[7], $st[9], $digest);
        },
    }, $root);
    return join("\n", sort @rows);
}

return sub {
    my ($assert) = @_;

    my $contract = JSON::PP->new->decode(
        _slurp_1151('plugins/API_V3_CONTRACT.json'));
    my $accepted = $contract->{production_update_acceptance} || {};

    $assert->is($contract->{milestone}, 'MB786',
        'machine contract advances to updater acceptance consolidation');
    $assert->is($accepted->{milestone}, 'MB785',
        'live production proof remains anchored to MB785');
    $assert->is($accepted->{source_consolidation_milestone}, 'MB786',
        'source consolidation is named separately');
    $assert->is($accepted->{instance}, 'nbot',
        'accepted production instance is exact');
    $assert->is($accepted->{channel}, '#i/o',
        'accepted production channel is exact');
    $assert->is($accepted->{trigger}, 'authenticated IRC update now',
        'accepted update trigger is authenticated and explicit');
    $assert->is($accepted->{previous_commit}, '62820dc',
        'previous production commit is recorded');
    $assert->is($accepted->{previous_version},
        '3.6dev-20260924_144509',
        'previous production version is recorded');
    $assert->is($accepted->{installed_commit}, '7db72ea',
        'installed production commit is recorded');
    $assert->is($accepted->{installed_version},
        '3.6dev-20260924_204823',
        'installed production version is recorded');
    $assert->is($accepted->{durable_status}, 'success/completed',
        'durable updater result is exact');
    $assert->is(join(',', @{ $accepted->{staged_validation} || [] }),
        'Perl syntax,startup integrity',
        'both staged pre-shutdown gates are explicit');
    $assert->is(join(',', @{ $accepted->{systemd_contract} || [] }),
        'Restart=always,ExitType=cgroup',
        'accepted service lifecycle contract is exact');
    $assert->is($accepted->{snapshot_order},
        'after bot stop and before release rotation',
        'stable snapshot ordering is explicit');
    $assert->is($accepted->{previous_release_archive},
        '/home/mediabot/mediabot_v3.229',
        'exact rollback archive is recorded');
    $assert->is(join(',', @{ $accepted->{packages} || [] }),
        'quotes-v3,channel-activity-v3,factoids-v3,playful-v3,short-content-v3',
        'all five accepted packages are recorded in order');
    $assert->is($accepted->{final_mode}, 'on',
        'the complete portfolio remains authoritative');
    $assert->is($accepted->{plugin_failures}, 0,
        'production plugins finished with zero failures');
    $assert->like($accepted->{plugin_data},
        qr/complete tree.*byte.*mode.*ownership.*timestamp/i,
        'complete plugin-data metadata boundary is recorded');
    $assert->is($accepted->{boot_ledger}, 'byte-for-byte exact',
        'boot ledger preservation is exact');
    $assert->like($accepted->{short_content_kv},
        qr/byte-for-byte exact.*MB783 retained revision/i,
        'retained Short Content state is exact');
    $assert->is($accepted->{business_data_mutation}, 'none',
        'quote and factoid data remained unchanged');
    $assert->is($accepted->{temporary_identity}, 'removed',
        'temporary production identity cleanup is explicit');
    $assert->is($accepted->{irc_marker},
        'MB785-NBOT-20260925T132057Z-354760',
        'accepted IRC marker is exact');
    $assert->is($accepted->{production_replay_by_mb786}, 0,
        'MB786 explicitly performs no production replay');
    $assert->is($accepted->{development_ledger_change}, 'none',
        'MB786 changes no development posture');
    $assert->is($accepted->{runtime_authority_change}, 'none',
        'MB786 grants no runtime authority');

    my $deploy = _slurp_1151('install/deploy_update.sh');
    my $stop = index($deploy, 'Bot stopped.');
    my $copy = index($deploy, 'cp -a -- "${PLUGIN_DATA_SOURCE}"');
    my $rotate = index($deploy, 'Archiving current release:');
    $assert->ok($stop >= 0 && $copy > $stop && $rotate > $copy,
        'source keeps stop, stable snapshot and rotation in strict order');
    $assert->like($deploy,
        qr/Staged release passed the integrity check/,
        'startup integrity remains a pre-activation gate');
    $assert->like($deploy,
        qr/write_update_status "success".*?"\$STATUS_PHASE"/s,
        'successful rotation finalizes durable state');

    for my $doc (
        ['docs/PLUGIN_V3_UPDATE_ACCEPTANCE.md',
            qr/MB785.*62820dc.*7db72ea.*success\/completed.*mediabot_v3\.229/is],
        ['docs/PLUGIN_V3_PRODUCTION_PORTFOLIO.md',
            qr/MB785 release-rotation acceptance.*five packages.*zero failures/is],
        ['docs/PLUGIN_API_V3.md',
            qr/MB785.*real authenticated IRC updater.*MB786.*end-to-end rotation rehearsal/is],
        ['docs/PLUGIN_OPERATIONS_V3.md',
            qr/MB785 production update acceptance.*Restart=always.*ExitType=cgroup/is],
        ['docs/PLUGIN_ARCHITECTURE.md',
            qr/MB786.*production update acceptance consolidation.*isolated executable rehearsal/is],
        ['docs/adr/0001-plugin-platform-evolution.md',
            qr/MB785 validates.*real production release rotation.*MB786 accepts/is],
        ['CHANGELOG.md',
            qr/MB786.*moving staircase.*isolated end-to-end updater rehearsal/is],
    ) {
        $assert->like(_slurp_1151($doc->[0]), $doc->[1],
            "$doc->[0] records the accepted update boundary");
    }

    # Exercise the real updater against two local Git revisions. The fake bot
    # writes its final state only from SIGTERM; seeing that file in the new
    # release proves the snapshot happened after process shutdown.
    my $tmp = tempdir('mb786-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my $origin = File::Spec->catdir($tmp, 'origin');
    my $live = File::Spec->catdir($tmp, 'mb786-live');
    make_path($origin);

    my $fake_conf = <<'CONF';
package Mediabot::Conf;
use strict;
use warnings;
sub new {
    my ($class, undef, $path) = @_;
    open my $fh, '<', $path or die "$path: $!";
    my %values;
    while (<$fh>) {
        next if /^\s*(?:#|$)/;
        $values{$1} = $2 if /^\s*([A-Za-z0-9_.-]+)\s*=\s*(\S+)\s*$/;
    }
    close $fh;
    return bless { values => \%values }, $class;
}
sub get { return $_[0]{values}{$_[1]}; }
1;
CONF

    my $fake_bot = <<'BOT';
#!/usr/bin/env perl
use strict;
use warnings;
use File::Path qw(make_path);
make_path('var');
open my $ready, '>', 'var/mb786.ready' or die $!;
print {$ready} "ready\n";
close $ready;
$SIG{TERM} = sub {
    open my $fh, '>', 'plugin-data/shutdown-marker.txt' or die $!;
    print {$fh} "settled before snapshot\n";
    close $fh;
    chmod 0600, 'plugin-data/shutdown-marker.txt';
    exit 0;
};
sleep 1 while 1;
BOT

    my $fake_integrity = <<'INTEGRITY';
#!/usr/bin/env perl
use strict;
use warnings;
if (($ARGV[0] // '') eq '--gen-manifest') {
    open my $fh, '>', $ARGV[1] or die $!;
    print {$fh} "mb786\n";
    close $fh;
    exit 0;
}
if (($ARGV[0] // '') eq '--manifest') {
    exit(-f ($ARGV[1] // '') ? 0 : 1);
}
die "unsupported integrity invocation\n";
INTEGRITY

    _write_1151(File::Spec->catfile($origin, 'install', 'deploy_update.sh'),
        $deploy, 0755);
    _write_1151(File::Spec->catfile($origin, 'Mediabot', 'Conf.pm'),
        $fake_conf, 0644);
    _write_1151(File::Spec->catfile($origin, 'tools',
        'startup_integrity_check.pl'), $fake_integrity, 0755);
    _write_1151(File::Spec->catfile($origin, 'mediabot.pl'),
        $fake_bot, 0755);
    _write_1151(File::Spec->catfile($origin, 'VERSION'),
        "3.6dev-mb786-old\n", 0644);

    _must_run_1151($origin, 'git', 'init', '-q');
    _must_run_1151($origin, 'git', 'config', 'user.name', 'MB786 Test');
    _must_run_1151($origin, 'git', 'config', 'user.email',
        'mb786-test@example.invalid');
    _must_run_1151($origin, 'git', 'add', '.');
    _must_run_1151($origin, 'git', 'commit', '-q', '-m', 'old release');
    _must_run_1151($tmp, 'git', 'clone', '-q', $origin, $live);

    _write_1151(File::Spec->catfile($origin, 'VERSION'),
        "3.6dev-mb786-new\n", 0644);
    _write_1151(File::Spec->catfile($origin, 'TARGET'),
        "reviewed candidate\n", 0644);
    _must_run_1151($origin, 'git', 'add', 'VERSION', 'TARGET');
    _must_run_1151($origin, 'git', 'commit', '-q', '-m', 'new release');

    _write_1151(File::Spec->catfile($live, 'mediabot.conf'),
        "plugins.DATA_DIR=plugin-data\n", 0600);
    my $data = File::Spec->catdir($live, 'plugin-data');
    my $kv_dir = File::Spec->catdir($data, 'repositories');
    make_path($kv_dir, { mode => 0700 });
    chmod 0700, $data, $kv_dir;
    my $ledger = File::Spec->catfile($data,
        '.api-v3-runtime-state.json');
    my $kv = File::Spec->catfile($kv_dir, 'short-content-v3.json');
    _write_1151($ledger,
        qq|{"schema":1,"packages":{"short-content-v3":{"enabled":true}}}\n|,
        0600);
    _write_1151($kv,
        qq|{"revision":1,"value":"MB783-mediabot_v3"}\n|, 0600);
    my $fixed_time = 1_790_000_000;
    utime $fixed_time, $fixed_time, $ledger, $kv;

    # The updater waits with kill(0), which remains true for an unreaped
    # zombie. Give the fake bot a tiny dedicated reaper, matching the real
    # service manager's process-reaping behavior.
    my $bot_pid_file = File::Spec->catfile($tmp, 'fake-bot.pid');
    my $bot_reaper = fork();
    die "fork fake bot reaper: $!" unless defined $bot_reaper;
    if ($bot_reaper == 0) {
        my $bot_pid = fork();
        die "fork fake bot: $!" unless defined $bot_pid;
        if ($bot_pid == 0) {
            chdir $live or die "chdir $live: $!";
            exec { $^X } $^X, './mediabot.pl', '--conf=mediabot.conf'
                or die "exec fake bot: $!";
        }
        open my $pid_fh, '>', $bot_pid_file or die "$bot_pid_file: $!";
        print {$pid_fh} "$bot_pid\n";
        close $pid_fh or die "$bot_pid_file: $!";
        waitpid($bot_pid, 0);
        exit($? >> 8);
    }

    my $ready = File::Spec->catfile($live, 'var', 'mb786.ready');
    for (1 .. 100) {
        last if -f $ready;
        select undef, undef, undef, 0.05;
    }
    $assert->ok(-f $ready, 'disposable bot reached its running barrier');

    # GitHub's hosted runner puts every child under its own systemd service.
    # The disposable bot inherits that cgroup even though the tiny reaper,
    # rather than systemd, owns its lifetime. Scope a systemctl stand-in to
    # this one bot so the real updater exercises its systemd-safe branch while
    # the production unit check in deploy_update.sh remains untouched.
    my $fixture_pid = _slurp_1151($bot_pid_file, 1);
    chomp $fixture_pid;
    die "invalid disposable bot PID\n" unless $fixture_pid =~ /\A\d+\z/;
    my $fixture_unit = '';
    if (open my $cgroup_fh, '<', "/proc/$fixture_pid/cgroup") {
        while (my $line = <$cgroup_fh>) {
            if ($line =~ m{/([^/\s]+\.service)\s*$}) {
                $fixture_unit = $1;
                last;
            }
        }
        close $cgroup_fh;
    }

    my $update_log = File::Spec->catfile($tmp, 'update.log');
    local $ENV{LC_ALL} = 'C';
    my @update_command = (
        File::Spec->catfile($live, 'install', 'deploy_update.sh'),
        '--conf=mediabot.conf',
    );
    my $update_rc;
    if (length $fixture_unit) {
        my $fixture_bin = File::Spec->catdir($tmp, 'fixture-bin');
        make_path($fixture_bin);
        _write_1151(File::Spec->catfile($fixture_bin, 'systemctl'), <<'SYSTEMCTL', 0755);
#!/bin/sh
set -eu
[ "$#" -eq 4 ] && [ "$1" = show ] && [ "$4" = --value ] || exit 2
[ "$2" = "${MB786_FIXTURE_UNIT:-}" ] || exit 2
case "${MB786_FIXTURE_BOT_PID:-}" in ''|*[!0-9]*) exit 2 ;; esac
[ -r "/proc/${MB786_FIXTURE_BOT_PID}/cgroup" ] || exit 2
actual="$(awk -F: '{print $3}' "/proc/${MB786_FIXTURE_BOT_PID}/cgroup" \
  | sed -n 's#^.*/\([^/]*\.service\)$#\1#p' | head -1)"
[ "$actual" = "$2" ] || exit 2
case "$3" in
  --property=Restart) printf 'always\n' ;;
  --property=ExitType) printf 'cgroup\n' ;;
  *) exit 2 ;;
esac
SYSTEMCTL
        local $ENV{PATH} = "$fixture_bin:$ENV{PATH}";
        local $ENV{MB786_FIXTURE_UNIT} = $fixture_unit;
        local $ENV{MB786_FIXTURE_BOT_PID} = $fixture_pid;
        $update_rc = _run_1151($live, $update_log, @update_command);
    } else {
        $update_rc = _run_1151($live, $update_log, @update_command);
    }
    my $update_output = _slurp_1151($update_log, 1);
    warn "MB786 updater rehearsal failed:\n$update_output\n" if $update_rc;

    my $waited = waitpid($bot_reaper, WNOHANG);
    if ($waited == 0) {
        if (-f $bot_pid_file) {
            my $stray_pid = _slurp_1151($bot_pid_file, 1);
            chomp $stray_pid;
            kill 'TERM', $stray_pid if $stray_pid =~ /\A\d+\z/;
        }
        waitpid($bot_reaper, 0);
    }
    $assert->is($update_rc, 0,
        'isolated real updater completed successfully');
    return if $update_rc;
    if (length $fixture_unit) {
        $assert->like($update_output,
            qr/\Qsystemd instance: $fixture_unit (Restart=always, ExitType=cgroup)\E/,
            'hosted runner exercises the updater systemd lifecycle gate');
    }
    $assert->is($waited, $bot_reaper,
        'updater stopped the exact disposable bot before returning');
    $assert->like($update_output,
        qr/Staged release passed the integrity check/,
        'isolated candidate passed startup-integrity validation');

    my $log_stop = index($update_output, 'Bot stopped.');
    my $log_copy = index($update_output, 'Preserved instance plugin data:');
    my $log_rotate = index($update_output, 'Archiving current release:');
    $assert->ok($log_stop >= 0 && $log_copy > $log_stop
            && $log_rotate > $log_copy,
        'runtime output proves stop, snapshot and rotation order');

    my $archive = "$live.1";
    $assert->ok(-d $archive,
        'one exact previous-release archive remains');
    $assert->is(_slurp_1151(File::Spec->catfile($live, 'VERSION')),
        "3.6dev-mb786-new\n",
        'reviewed candidate occupies the live path');
    $assert->is(_slurp_1151(File::Spec->catfile($archive, 'VERSION')),
        "3.6dev-mb786-old\n",
        'previous version remains in the exact archive');
    $assert->is(_slurp_1151(File::Spec->catfile($live, 'plugin-data',
        'shutdown-marker.txt')), "settled before snapshot\n",
        'post-SIGTERM state reached the activated release');

    my $live_manifest = _tree_manifest_1151(
        File::Spec->catdir($live, 'plugin-data'));
    my $archive_manifest = _tree_manifest_1151(
        File::Spec->catdir($archive, 'plugin-data'));
    $assert->is($live_manifest, $archive_manifest,
        'complete plugin-data bytes and metadata match the stopped source');

    my @ledger_stat = stat(File::Spec->catfile($live, 'plugin-data',
        '.api-v3-runtime-state.json'));
    my @kv_stat = stat(File::Spec->catfile($live, 'plugin-data',
        'repositories', 'short-content-v3.json'));
    $assert->is(sprintf('%04o', $ledger_stat[2] & 07777), '0600',
        'boot ledger mode survives rotation');
    $assert->is($ledger_stat[9], $fixed_time,
        'boot ledger stable timestamp survives rotation');
    $assert->is(sprintf('%04o', $kv_stat[2] & 07777), '0600',
        'Short Content KV mode survives rotation');
    $assert->is($kv_stat[9], $fixed_time,
        'Short Content KV stable timestamp survives rotation');

    my $status_path = File::Spec->catfile($tmp,
        '.mb786-live.update-status.json');
    my $status = JSON::PP->new->decode(_slurp_1151($status_path, 1));
    $assert->is($status->{state}, 'success',
        'durable rehearsal status reports success');
    $assert->is($status->{phase}, 'completed',
        'durable rehearsal status reaches completed');
    $assert->is($status->{old_version}, '3.6dev-mb786-old',
        'durable status records the old version');
    $assert->is($status->{target_version}, '3.6dev-mb786-new',
        'durable status records the target version');
    $assert->is($status->{installed_version}, '3.6dev-mb786-new',
        'durable status records the installed version');
};
