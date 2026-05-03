# t/cases/46_hailo_exact_match.t
# =============================================================================
# Static regression checks for exact Hailo lookups.
#
# Hailo exclusion nicks and channel names are identifiers, not SQL LIKE patterns.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_hailo_exact_match {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_hailo_exact_match(File::Spec->catfile('.', 'Mediabot', 'Hailo.pm'));

    $assert->ok(
        $src =~ /SELECT 1 FROM HAILO_EXCLUSION_NICK WHERE nick = \?/,
        'Hailo exclusion nick lookup uses exact match'
    );

    $assert->ok(
        $src =~ /WHERE CHANNEL\.name = \?/,
        'Hailo channel ratio lookup uses exact channel match'
    );

    $assert->ok(
        $src !~ /HAILO_EXCLUSION_NICK WHERE nick LIKE \?/,
        'Hailo exclusion nick lookup no longer uses LIKE'
    );

    $assert->ok(
        $src !~ /CHANNEL\.name LIKE \?/,
        'Hailo channel ratio lookup no longer uses LIKE'
    );
};
