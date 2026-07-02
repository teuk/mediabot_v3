# t/cases/145_admin_status_no_external_uptime_uname.t
# =============================================================================
# Regression checks for AdminCommands::mbStatus_ctx().
#
# Status should not spawn external uptime/uname processes. /proc/uptime and
# POSIX::uname are enough and avoid unnecessary process creation.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_admin_status_no_external {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_admin_status_no_external {
    my ($src, $sub_name) = @_;

    my $start_re = qr/^sub\s+\Q$sub_name\E\s*\{/m;
    return undef unless $src =~ /$start_re/g;

    my $start = pos($src);
    my $depth = 1;
    my $pos   = $start;
    my $len   = length($src);

    while ($pos < $len) {
        my $char = substr($src, $pos, 1);

        if ($char eq '{') {
            $depth++;
        }
        elsif ($char eq '}') {
            $depth--;

            if ($depth == 0) {
                return substr($src, $start, $pos - $start);
            }
        }

        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_admin_status_no_external(
        File::Spec->catfile('.', 'Mediabot', 'AdminCommands.pm')
    );

    my $body = _extract_sub_body_admin_status_no_external($src, 'mbStatus_ctx');

    $assert->ok(
        defined $body,
        'mbStatus_ctx body found'
    );

    $assert->like(
        $src,
        qr/^use Sys::Hostname qw\(hostname\);$/m,
        'AdminCommands.pm imports Sys::Hostname hostname'
    );

    $assert->like(
        $body // '',
        qr/open my \$fh_uptime, '<', '\/proc\/uptime'/,
        'mbStatus_ctx reads /proc/uptime directly'
    );

    $assert->like(
        $body // '',
        qr/POSIX::uname\(\)/,
        'mbStatus_ctx uses POSIX::uname for OS info'
    );

    $assert->like(
        $body // '',
        qr/hostname\(\)/,
        'mbStatus_ctx uses Sys::Hostname for hostname'
    );

    $assert->unlike(
        $body // '',
        qr/open my \$fh_uptime, '-\|', 'uptime'/,
        'mbStatus_ctx no longer spawns uptime'
    );

    $assert->unlike(
        $body // '',
        qr/open my \$fh_uname, '-\|', 'uname -a'/,
        'mbStatus_ctx no longer spawns uname'
    );

    $assert->unlike(
        $body // '',
        qr/Could not execute 'uptime' command/,
        'mbStatus_ctx no longer logs external uptime execution failure'
    );

    $assert->unlike(
        $body // '',
        qr/Could not execute 'uname' command/,
        'mbStatus_ctx no longer logs external uname execution failure'
    );

    $assert->like(
        $body // '',
        qr/"Server: \$uname \| uptime \$server_uptime"/,
        'mbStatus_ctx reports uname and server uptime in one compact line'
    );

    $assert->like(
        $body // '',
        qr/details: status full/,
        'mbStatus_ctx advertises the bounded detailed Scheduler mode'
    );
};
