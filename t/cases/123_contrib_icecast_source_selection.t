# t/cases/123_contrib_icecast_source_selection.t
# =============================================================================
# Regression checks for contrib Icecast helper scripts.
#
# Icecast status-json.xsl may expose icestats.source either as:
#   - a HASH when there is one mount;
#   - an ARRAY when there are multiple mounts.
#
# The --source index must be used only for ARRAY sources.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_contrib_icecast_source_selection {
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
        my $src = _slurp_contrib_icecast_source_selection($script);

        $assert->like(
            $src,
            qr/"source=i"\s*=>\s*\\\$RADIO_SOURCE/,
            "$script accepts --source"
        );

        $assert->like(
            $src,
            qr/my\s+\$sources\s*=\s*\$json->\{'icestats'\}\{'source'\}/,
            "$script reads icestats.source into a scalar"
        );

        $assert->like(
            $src,
            qr/ref\(\$sources\)\s+eq\s+'ARRAY'/,
            "$script handles Icecast multi-source ARRAY output"
        );

        $assert->like(
            $src,
            qr/\$selected_source\s*=\s*\$sources->\[\$RADIO_SOURCE\]/,
            "$script uses RADIO_SOURCE as the ARRAY index"
        );

        $assert->like(
            $src,
            qr/ref\(\$sources\)\s+eq\s+'HASH'/,
            "$script handles Icecast single-source HASH output"
        );

        $assert->like(
            $src,
            qr/defined\(\$selected_source\)\s*&&\s*ref\(\$selected_source\)\s+eq\s+'HASH'/,
            "$script only dereferences a valid selected HASH source"
        );

        $assert->unlike(
            $src,
            qr/my\s+\@sources\s*=\s*\$json->\{'icestats'\}\{'source'\}/,
            "$script no longer stores icestats.source in a misleading array"
        );

        $assert->unlike(
            $src,
            qr/my\s+%source\s*=\s*%\{\$sources\[0\]\}/,
            "$script no longer always uses source index 0"
        );
    }
};
