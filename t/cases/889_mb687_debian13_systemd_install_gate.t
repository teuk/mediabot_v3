# t/cases/889_mb687_debian13_systemd_install_gate.t
# =============================================================================
# MB687 — Debian 13 must exercise a safe, idempotent installation path for the
# published systemd template and instance environment without pretending that
# a container has performed a live PID1/service/IRC end-to-end validation.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Path qw(make_path remove_tree);
use File::Spec;
use File::Temp qw(tempdir);

sub _slurp_889 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

sub _write_889 {
    my ($path, $content) = @_;
    open my $fh, '>:encoding(UTF-8)', $path or die "$path: $!";
    print {$fh} $content;
    close $fh or die "$path: $!";
}

return sub {
    my ($assert) = @_;

    my $workflow = _slurp_889(File::Spec->catfile('.', '.github', 'workflows', 'debian13.yml'));
    my $helper   = _slurp_889(File::Spec->catfile('.', 'install', 'systemd_install.sh'));
    my $unit     = _slurp_889(File::Spec->catfile('.', 'tools', 'systemd', 'mediabot@.service.example'));
    my $sysdoc   = _slurp_889(File::Spec->catfile('.', 'tools', 'systemd', 'README.md'));
    my $readme   = _slurp_889(File::Spec->catfile('.', 'README.md'));

    $assert->like(
        $workflow,
        qr/^\s*systemd\s*\\?\s*$/m,
        'Debian 13 bootstrap explicitly installs the systemd verification tools',
    );
    $assert->like(
        $workflow,
        qr/name:\s*Exercise systemd installation and static unit validation/,
        'Debian 13 workflow contains a dedicated systemd installation step',
    );
    $assert->like(
        $workflow,
        qr/install\/systemd_install\.sh\s+\\.*?--root "\$SYSTEMD_ROOT".*?--instance ci.*?--bot-dir \/home\/mediabot\/mediabot_v3/s,
        'CI exercises the real systemd installer against an isolated filesystem root',
    );
    $assert->like(
        $workflow,
        qr/cmp tools\/systemd\/mediabot\@\.service\.example "\$SYSTEMD_ROOT\/etc\/systemd\/system\/mediabot\@\.service"/,
        'CI proves the installed unit is byte-identical to the published template',
    );
    $assert->like(
        $workflow,
        qr/systemd-analyze verify "\$SYSTEMD_ROOT\/etc\/systemd\/system\/mediabot\@\.service"/,
        'Debian 13 systemd parser statically verifies the installed unit',
    );
    $assert->like(
        $workflow,
        qr/install\/systemd_install\.sh.*?--replace-template/s,
        'CI exercises explicit replacement of a deliberately drifted template',
    );
    $assert->like(
        $workflow,
        qr/-f '\^\(.*?888_\|889_.*?\)'/,
        'Debian 13 workflow includes the MB687 contract',
    );

    $assert->like($helper, qr/^set -euo pipefail$/m,
        'systemd installer is fail-closed at shell level');
    $assert->like($helper, qr/--replace-template/,
        'template replacement requires an explicit option');
    $assert->like($helper, qr/--replace-instance/,
        'instance environment replacement requires an explicit option');
    $assert->like($helper, qr/--template-only/,
        'existing installations can update only the shared template');
    $assert->like($helper, qr/if \[ -L "\$target" \].*?refusing/s,
        'installer refuses symlink targets before writing');
    $assert->like($helper, qr/cmp -s "\$source" "\$target"/,
        'matching files are detected and kept idempotently');
    $assert->like($helper, qr/current Mediabot template requires systemd >= 250/,
        'real-root installation fails closed on systemd versions too old for ExitType=cgroup');
    $assert->like($helper, qr/systemctl daemon-reload/,
        'real-root file changes reload systemd metadata');
    $assert->unlike($helper, qr/^\s*systemctl\s+(?:start|restart|stop|enable|disable)\b/m,
        'installer never starts, restarts, stops, enables, or disables a service implicitly');

    for my $required (
        'ExitType=cgroup',
        'Environment=MEDIABOT_SYSTEMD_UPDATE_SAFE=1',
        'Restart=always',
        'SuccessExitStatus=75',
        'RestartPreventExitStatus=75',
    ) {
        $assert->like($unit, qr/^\Q$required\E$/m,
            "published template retains lifecycle contract: $required");
    }

    $assert->like(
        $sysdoc,
        qr/install\/systemd_install\.sh.*?--instance dev.*?--bot-dir \/home\/mediabot\/mediabot_v3/s,
        'systemd guide documents the supported installer for a fresh instance',
    );
    $assert->like(
        $sysdoc,
        qr/--template-only --replace-template/,
        'systemd guide documents safe template-only upgrade for an existing installation',
    );
    $assert->like(
        $sysdoc,
        qr/does not start, restart, or enable the bot automatically/i,
        'systemd guide states the no-implicit-runtime-change contract',
    );
    $assert->like(
        $readme,
        qr/systemd installation helper.*?systemd-analyze verify/s,
        'README includes the new static systemd installation proof',
    );
    $assert->like(
        $readme,
        qr/Live systemd deployment and IRC\s+connectivity remain end-to-end runtime checks/s,
        'README preserves the live PID1/IRC acceptance boundary',
    );

    # Dynamic helper contract in an isolated fake filesystem root.
    my $tmp  = tempdir(CLEANUP => 1);
    my $root = File::Spec->catdir($tmp, 'root');
    my $bot  = File::Spec->catdir($root, 'home', 'mediabot', 'mediabot_v3');
    make_path($bot);
    _write_889(File::Spec->catfile($bot, 'mediabot.pl'), "#!/usr/bin/perl\n");
    _write_889(File::Spec->catfile($bot, 'mediabot.conf'), "fixture=1\n");

    my $fakebin = File::Spec->catdir($tmp, 'bin');
    make_path($fakebin);
    my $systemctl_log = File::Spec->catfile($tmp, 'systemctl.log');
    my $fake_systemctl = File::Spec->catfile($fakebin, 'systemctl');
    _write_889($fake_systemctl, <<'FAKE_SYSTEMCTL');
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MB687_SYSTEMCTL_LOG"
exit 97
FAKE_SYSTEMCTL
    chmod 0755, $fake_systemctl or die "chmod $fake_systemctl: $!";

    local $ENV{PATH} = "$fakebin:$ENV{PATH}";
    local $ENV{MB687_SYSTEMCTL_LOG} = $systemctl_log;

    my @base = (
        'bash', 'install/systemd_install.sh',
        '--root', $root,
        '--instance', 'ci',
        '--bot-dir', '/home/mediabot/mediabot_v3',
    );

    my $rc = system(@base);
    $assert->is($rc >> 8, 0,
        'isolated fresh systemd installation succeeds without a live systemd manager');

    my $installed_unit = File::Spec->catfile($root, 'etc', 'systemd', 'system', 'mediabot@.service');
    my $installed_env  = File::Spec->catfile($root, 'etc', 'default', 'mediabot-ci');
    $assert->is(_slurp_889($installed_unit), $unit,
        'installed unit is exactly the published template');
    $assert->like(_slurp_889($installed_env), qr/^BOT_DIR=\/home\/mediabot\/mediabot_v3$/m,
        'instance environment records the requested project directory');
    $assert->like(_slurp_889($installed_env), qr/^BOT_BIN=\/home\/mediabot\/mediabot_v3\/mediabot\.pl$/m,
        'instance environment derives the normal bot executable');
    $assert->like(_slurp_889($installed_env), qr/^BOT_CONF=\/home\/mediabot\/mediabot_v3\/mediabot\.conf$/m,
        'instance environment derives the normal bot configuration path');
    $assert->is(sprintf('%04o', (stat($installed_unit))[2] & 07777), '0644',
        'installed template has mode 0644');
    $assert->is(sprintf('%04o', (stat($installed_env))[2] & 07777), '0644',
        'installed instance environment has mode 0644');
    $assert->ok(!-e $systemctl_log,
        'alternate-root installation never invokes systemctl');

    $rc = system(@base);
    $assert->is($rc >> 8, 0,
        'rerunning the same installation is idempotent');

    open my $drift, '>>', $installed_unit or die "$installed_unit: $!";
    print {$drift} "\n# deliberate MB687 drift\n";
    close $drift;
    $rc = system(@base);
    $assert->ok(($rc >> 8) != 0,
        'divergent existing template is preserved by default');
    $rc = system(@base, '--replace-template');
    $assert->is($rc >> 8, 0,
        'divergent template can be replaced only by explicit request');
    $assert->is(_slurp_889($installed_unit), $unit,
        'explicit template replacement restores the published contract');

    open my $env_drift, '>>', $installed_env or die "$installed_env: $!";
    print {$env_drift} "EXTRA=preserve-me\n";
    close $env_drift;
    $rc = system(@base);
    $assert->ok(($rc >> 8) != 0,
        'divergent existing instance environment is preserved by default');
    $rc = system(@base, '--replace-instance');
    $assert->is($rc >> 8, 0,
        'instance environment replacement also requires explicit request');
    $assert->unlike(_slurp_889($installed_env), qr/EXTRA=preserve-me/,
        'explicit instance replacement writes the requested canonical values');

    unlink $installed_unit or die "unlink $installed_unit: $!";
    my $victim = File::Spec->catfile($tmp, 'victim');
    _write_889($victim, "do not touch\n");
    symlink $victim, $installed_unit or die "symlink: $!";
    $rc = system(@base, '--replace-template');
    $assert->ok(($rc >> 8) != 0,
        'template symlink target is refused even with explicit replacement');
    $assert->is(_slurp_889($victim), "do not touch\n",
        'symlink victim remains untouched');

    $rc = system(
        'bash', 'install/systemd_install.sh',
        '--root', $root,
        '--instance', '../escape',
        '--bot-dir', '/home/mediabot/mediabot_v3',
    );
    $assert->ok(($rc >> 8) != 0,
        'unsafe instance names are rejected');
};
