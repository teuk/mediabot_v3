# t/cases/890_mb688_generic_instance_updater.t
# =============================================================================
# MB688 — generic instance updater contract.
#
# The updater must no longer assume one deployment directory/config pair.
# The public contract stays generic:
#   - current directory basename drives archive/temp/failed names;
#   - current Git origin drives the clone source;
#   - --conf selects the private config, with mediabot.conf as default;
#   - IRC update forwards the bot's actual config_file;
#   - root-level .brn and local mp3/ state survive rotation;
#   - mp3/ is ignored by Git;
#   - no host-private instance name is added to the product.
# =============================================================================

use strict;
use warnings;
use utf8;

sub _slurp_890 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $deploy = _slurp_890('install/deploy_update.sh');
    my $update = _slurp_890('Mediabot/Update.pm');
    my $ignore = _slurp_890('.gitignore');

    $assert->like($deploy,
        qr/INSTANCE_CONF="\$\{MEDIABOT_UPDATE_CONF:-mediabot\.conf\}"/,
        'mb688-890: mediabot.conf remains the default');
    $assert->like($deploy, qr/--conf=\*/,
        'mb688-890: --conf=<file> is accepted');
    $assert->like($deploy, qr/--conf\)\s*.*?INSTANCE_CONF="\$2"/s,
        'mb688-890: --conf <file> is accepted');
    $assert->like($deploy, qr/-h\|--help\)/,
        'mb688-890: updater has a real help path');
    $assert->like($deploy,
        qr/instance config must live directly in \$\{PROJECT_DIR\}/,
        'mb688-890: selected config cannot escape the instance root');
    $assert->like($deploy,
        qr/cp -pfv "\$\{INSTANCE_CONF_REAL\}" "\$\{TMP_CLONE_DIR\}\/\$\{INSTANCE_CONF_NAME\}"/,
        'mb688-890: selected private config is preserved exactly');

    $assert->unlike($deploy,
        qr/project directory name is .*expected 'mediabot_v3'/,
        'mb688-890: no fixed mediabot_v3 directory requirement remains');
    $assert->like($deploy,
        qr/BACKUP_DIR="\$\{PARENT_DIR\}\/\$\{PROJECT_NAME\}\.\$\{NEXT_VER\}"/,
        'mb688-890: archive family derives from PROJECT_NAME');
    $assert->like($deploy,
        qr/mktemp -d "\$\{PARENT_DIR\}\/\$\{PROJECT_NAME\}\.new\.XXXXXX"/,
        'mb688-890: temporary clone family derives from PROJECT_NAME');
    $assert->like($deploy,
        qr/FAILED_DIR="\$\{PARENT_DIR\}\/\$\{PROJECT_NAME\}\.failed\.\$\$"/,
        'mb688-890: failed tree family derives from PROJECT_NAME');

    $assert->like($deploy,
        qr/ORIGIN_URL="\$\(git -C "\$\{PROJECT_DIR\}" remote get-url origin/,
        'mb688-890: clone source is resolved from current Git origin');
    $assert->like($deploy,
        qr/git clone "\$\{ORIGIN_URL\}" "\$\{TMP_CLONE_DIR\}"/,
        'mb688-890: candidate clone uses resolved origin');

    $assert->like($deploy,
        qr/\[ "\$CONF_REAL" = "\$INSTANCE_CONF_REAL" \]/,
        'mb688-890: updater targets the exact selected config');
    $assert->like($deploy, qr/mapfile -d '' -t PROC_ARGV/,
        'mb688-890: process matching reads real NUL-separated argv');
    $assert->like($deploy, qr/mediabot\.pl\|\*\/mediabot\.pl/,
        'mb688-890: process matching requires a real mediabot.pl argv item');
    $assert->unlike($deploy, qr/CMDLINE="\$\(tr '\\0' ' '/,
        'mb688-890: updater no longer flattens cmdline into shell text');
    $assert->unlike($deploy, qr/kill -9/,
        'mb688-890: updater never SIGKILLs a bot that fails to stop');
    $assert->like($deploy, qr/refusing SIGKILL and leaving the live tree untouched/,
        'mb688-890: stop timeout fails closed before rotation');

    $assert->like($deploy,
        qr/find "\$\{PROJECT_DIR\}" -maxdepth 1 -type f -name '\*\.brn' -print0/,
        'mb688-890: every current root brain is preserved');
    $assert->like($deploy,
        qr/\[ -d "\$\{PROJECT_DIR\}\/var\/hailo" \].*?cp -a "\$\{PROJECT_DIR\}\/var\/hailo"/s,
        'mb720-890: private per-channel brain directory is preserved');
    $assert->like($deploy,
        qr/\[ -L "\$\{PROJECT_DIR\}\/var\/hailo" \].*?refusing symbolic-link Hailo brain directory/s,
        'mb720-890: updater refuses a symlinked per-channel brain root');
    $assert->like($deploy,
        qr/\[ -d "\$\{PROJECT_DIR\}\/mp3" \].*?cp -a "\$\{PROJECT_DIR\}\/mp3"/s,
        'mb688-890: local mp3 state is preserved');
    $assert->like($ignore, qr/^mp3\/$/m,
        'mb688-890: mp3 is ignored by Git');

    $assert->like($update,
        qr/my \$config_file = \$self->\{config_file\}/,
        'mb688-890: IRC updater reads bot config_file');
    $assert->like($update,
        qr/push \@exec, '--conf=' \. \$config_file/,
        'mb688-890: IRC updater forwards config_file to deploy_update.sh');
    $assert->like($update,
        qr/exec \{ \$script \} \@exec/,
        'mb688-890: detached updater executes argv safely');

    $assert->unlike($deploy, qr/mbundernet|mediabot3|mediabot2/i,
        'mb688-890: shell updater contains no private instance label');
    $assert->unlike($update, qr/mbundernet|mediabot3|mediabot2/i,
        'mb688-890: IRC updater contains no private instance label');
};
