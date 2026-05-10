# t/cases/123_contrib_icecast_source_selection.t
# =============================================================================
# Regression checks for contrib Icecast --source selection.
#
# Icecast status-json.xsl can return:
#   - icestats.source as an ARRAY when several mounts exist;
#   - icestats.source as a HASH when only one mount exists.
#
# The helper scripts must validate icestats first, then read source into a
# scalar, then select the requested source safely.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_123 {
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
        my $src = _slurp_123($script);

        $assert->like(
            $src,
            qr/"source=i"\s*=>\s*\\\$RADIO_SOURCE/,
            "$script accepts --source integer option"
        );

        $assert->like(
            $src,
            qr/my\s+\$icestats\s*=\s*ref\(\$json->\{'icestats'\}\)\s+eq\s+'HASH'\s+\?\s+\$json->\{'icestats'\}\s+:\s+undef;/,
            "$script validates icestats before reading source"
        );

        $assert->like(
            $src,
            qr/unless\s+\(defined\(\$icestats\)\)/,
            "$script handles missing icestats"
        );

        $assert->like(
            $src,
            qr/my\s+\$sources\s*=\s*\$icestats->\{'source'\};/,
            "$script reads icestats.source into a scalar after validation"
        );

        $assert->like(
            $src,
            qr/if\s+\(ref\(\$sources\)\s+eq\s+'ARRAY'\)/,
            "$script handles Icecast multi-source ARRAY output"
        );

        $assert->like(
            $src,
            qr/\$RADIO_SOURCE\s+>\s+\$#\$sources/,
            "$script checks out-of-range source index"
        );

        $assert->like(
            $src,
            qr/\$selected_source\s*=\s*\$sources->\[\$RADIO_SOURCE\];/,
            "$script selects requested source from ARRAY"
        );

        $assert->like(
            $src,
            qr/elsif\s+\(ref\(\$sources\)\s+eq\s+'HASH'\)/,
            "$script handles Icecast single-source HASH output"
        );

        $assert->like(
            $src,
            qr/\$selected_source\s*=\s*\$sources;/,
            "$script uses HASH source directly when Icecast returns one source"
        );

        $assert->like(
            $src,
            qr/unless\s+\(defined\(\$selected_source\)\s+&&\s+ref\(\$selected_source\)\s+eq\s+'HASH'\)/,
            "$script validates selected source"
        );

        $assert->unlike(
            $src,
            qr/my\s+\$sources\s*=\s*\$json->\{'icestats'\}\{'source'\}/,
            "$script no longer reads icestats.source without validating icestats"
        );
    }
};
