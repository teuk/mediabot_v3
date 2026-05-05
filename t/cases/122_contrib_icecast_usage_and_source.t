# t/cases/122_contrib_icecast_usage_and_source.t
# =============================================================================
# Regression checks for contrib Icecast helper scripts.
#
# Their usage output must be copy/paste readable, and every option advertised
# in usage should be accepted by GetOptions().
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_contrib_icecast {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    for my $script (
        File::Spec->catfile('.', 'contrib', 'icecast2', 'getIcecastListeners.pl'),
        File::Spec->catfile('.', 'contrib', 'icecast2', 'getIcecastTitle.pl'),
    ) {
        my $src = _slurp_contrib_icecast($script);

        $assert->like(
            $src,
            qr/"host=s"\s*=>\s*\\\$RADIO_HOSTNAME/,
            "$script accepts --host"
        );

        $assert->like(
            $src,
            qr/"port=s"\s*=>\s*\\\$RADIO_PORT/,
            "$script accepts --port"
        );

        $assert->like(
            $src,
            qr/"source=i"\s*=>\s*\\\$RADIO_SOURCE/,
            "$script accepts --source advertised in usage"
        );

        $assert->like(
            $src,
            qr/basename\(\$0\)\s*\.\s*" --host <radio_hostname>/,
            "$script usage has a space before --host"
        );

        $assert->unlike(
            $src,
            qr/basename\(\$0\)\s*\.\s*"--host/,
            "$script usage does not glue script name and --host together"
        );

        $assert->like(
            $src,
            qr/\[--source <radio_source default: 0>\]/,
            "$script usage documents --source cleanly with closing bracket"
        );

        $assert->unlike(
            $src,
            qr/default\s+:\s+0\]/,
            "$script usage no longer uses the old spaced default format"
        );
    }
};
