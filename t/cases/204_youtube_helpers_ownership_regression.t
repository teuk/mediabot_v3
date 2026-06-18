# t/cases/204_youtube_helpers_ownership_regression.t
# =============================================================================
# Regression checks for YouTube helper ownership.
#
# YouTube-specific rendering helpers belong to Mediabot::External::YouTube. They must not
# be exported by Mediabot::Helpers, otherwise importing Helpers into External can
# cause subroutine redefinition warnings and stale formatting behavior.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_204 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $helpers = _slurp_204(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));
    my $external = _slurp_204(File::Spec->catfile('.', 'Mediabot', 'External', 'YouTube.pm'));

    $assert->unlike(
        $helpers,
        qr/^\s*_yt_badge\s*$/m,
        'Helpers.pm does not export stale _yt_badge'
    );

    $assert->unlike(
        $helpers,
        qr/^\s*sub\s+_yt_badge\b/m,
        'Helpers.pm does not define stale _yt_badge'
    );

    $assert->unlike(
        $helpers,
        qr/^\s*sub\s+_yt_format_duration\b/m,
        'Helpers.pm does not define stale _yt_format_duration'
    );

    for my $sub (qw(_yt_format_duration _yt_duration_seconds _yt_label _yt_text _yt_sep _yt_meta)) {
        $assert->like(
            $external,
            qr/^\s*sub\s+\Q$sub\E\b/m,
            "External/YouTube.pm owns $sub"
        );
    }
};
